#!/bin/zsh
set -eu

repo_root="${0:A:h:h}"
arch="${1:-$(uname -m)}"
out_dir="${2:-$repo_root/build/helpers-$arch}"
work_dir="${repo_root}/build/src-$arch"

mkdir -p "$out_dir/bin" "$work_dir/tools/bin" "$work_dir/ossl-static"

OPENCONNECT_VER="9.21"
OPENCONNECT_SHA256="5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58"
LIBEVENT_VER="2.1.13-stable"
LIBEVENT_SHA256="f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c"
OCPROXY_VER="1.60"
OCPROXY_SHA256="a7367647f07df33869e2f79da66b6f104f6495ae806b12a8b8d9ca82fb7899ac"
PKGCONF_VER="3.0.11"
PKGCONF_SHA256="d0cd841bc8e55b9da888106c00dc256d05b7d1d8e5a46f4be4eb4c5125bd2dc4"

sdk=$(xcrun --show-sdk-path)
jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

fetch_and_verify() {
    local url="$1" dest="$2" expected="$3"
    if [[ ! -f "$dest" ]]; then
        /usr/bin/curl -fLsS --max-time 60 -o "$dest" "$url"
    fi
    printf '%s  %s\n' "$expected" "$dest" | /usr/bin/shasum -a 256 -c
}

find_openssl_prefix() {
    local candidate
    for candidate in \
        "${OPENSSL_ROOT_DIR:-}" \
        "/opt/homebrew/opt/openssl@3" \
        "/usr/local/opt/openssl@3" \
        "/opt/nanobrew/prefix/opt/openssl@4" \
        "/opt/nanobrew/prefix/opt/openssl@3"; do
        if [[ -n "$candidate" && -f "$candidate/lib/libssl.a" && -f "$candidate/lib/libcrypto.a" ]]; then
            print -r -- "$candidate"
            return 0
        fi
    done
    return 1
}

openssl_dir=$(find_openssl_prefix) || {
    print -u2 "Could not locate static libssl.a/libcrypto.a. Set OPENSSL_ROOT_DIR or install openssl@3."
    exit 1
}
ln -sf "$openssl_dir/lib/libssl.a" "$work_dir/ossl-static/libssl.a"
ln -sf "$openssl_dir/lib/libcrypto.a" "$work_dir/ossl-static/libcrypto.a"

cd "$work_dir"

# 1. Build pkgconf if not present
if ! command -v pkgconf >/dev/null 2>&1 && ! command -v pkg-config >/dev/null 2>&1; then
    fetch_and_verify \
        "https://distfiles.ariadne.space/pkgconf/pkgconf-${PKGCONF_VER}.tar.xz" \
        "pkgconf-${PKGCONF_VER}.tar.xz" \
        "$PKGCONF_SHA256"
    /usr/bin/tar -xf "pkgconf-${PKGCONF_VER}.tar.xz"
    (
        cd "pkgconf-${PKGCONF_VER}"
        CC="/usr/bin/clang -arch $arch" CFLAGS="-O2 -mmacosx-version-min=14.0" \
            ./configure --prefix="$work_dir/tools" > configure.log 2>&1
        /usr/bin/make -j "$jobs" > build.log 2>&1
        /usr/bin/make install >> build.log 2>&1
    )
    pkgconf_bin="$work_dir/tools/bin/pkgconf"
else
    pkgconf_bin=$(command -v pkgconf || command -v pkg-config)
fi

# 2. Build static libevent
fetch_and_verify \
    "https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VER}/libevent-${LIBEVENT_VER}.tar.gz" \
    "libevent-${LIBEVENT_VER}.tar.gz" \
    "$LIBEVENT_SHA256"
/usr/bin/tar -xzf "libevent-${LIBEVENT_VER}.tar.gz"
(
    cd "libevent-${LIBEVENT_VER}"
    AR=/usr/bin/ar RANLIB=/usr/bin/ranlib \
        CC="/usr/bin/clang -arch $arch" CFLAGS="-O2 -mmacosx-version-min=14.0" \
        ./configure --prefix="$work_dir/tools" --disable-openssl --disable-samples --disable-libevent-regress --disable-shared > configure.log 2>&1
    /usr/bin/make -j "$jobs" AR=/usr/bin/ar RANLIB=/usr/bin/ranlib > build.log 2>&1
    /usr/bin/make install >> build.log 2>&1
)

# 3. Build ocproxy directly against static libevent
fetch_and_verify \
    "https://github.com/cernekee/ocproxy/archive/refs/tags/v${OCPROXY_VER}.tar.gz" \
    "ocproxy-v${OCPROXY_VER}.tar.gz" \
    "$OCPROXY_SHA256"
/usr/bin/tar -xzf "ocproxy-v${OCPROXY_VER}.tar.gz"
(
    cd "ocproxy-${OCPROXY_VER}"
    cat > config.h <<EOF
#define PACKAGE_NAME "ocproxy"
#define PACKAGE_VERSION "${OCPROXY_VER}"
EOF
    /usr/bin/python3 - "$arch" "$work_dir/tools" "$out_dir/bin/ocproxy" <<'PY'
import re, subprocess, sys
arch, tools_dir, out_bin = sys.argv[1:]
makefile = open("Makefile.am").read()
srcs = [s for s in dict.fromkeys(re.findall(r"(?:lwip|contrib|src)/[^\s\\]+\.c", makefile)) if s != "src/vpnns.c"]
cflags = [
    "-arch", arch, "-mmacosx-version-min=14.0",
    "-O2", "-Dunix", "-DIPv4", "-DHAVE_CONFIG_H",
    "-I.", "-Ilwip/src", "-Ilwip/src/include", "-Ilwip/src/include/ipv4",
    "-Ilwip/src/include/ipv6", "-Icontrib/ports/unix/include", "-Isrc",
    f"-I{tools_dir}/include",
    "-Wno-unused-parameter", "-Wno-sign-compare", "-Wno-pointer-sign"
]
objs = []
for src in srcs:
    obj = src.replace("/", "_") + ".o"
    subprocess.check_call(["/usr/bin/clang", *cflags, "-c", src, "-o", obj])
    objs.append(obj)
subprocess.check_call([
    "/usr/bin/clang", "-arch", arch, "-mmacosx-version-min=14.0",
    *objs, f"{tools_dir}/lib/libevent.a", "-lpthread", "-o", out_bin
])
PY
)

# 4. Build portable openconnect (static OpenSSL + Apple system libxml2/zlib/iconv)
fetch_and_verify \
    "https://www.infradead.org/openconnect/download/openconnect-${OPENCONNECT_VER}.tar.gz" \
    "openconnect-${OPENCONNECT_VER}.tar.gz" \
    "$OPENCONNECT_SHA256"
/usr/bin/tar -xzf "openconnect-${OPENCONNECT_VER}.tar.gz"
(
    cd "openconnect-${OPENCONNECT_VER}"
    env AR=/usr/bin/ar RANLIB=/usr/bin/ranlib PKG_CONFIG="$pkgconf_bin" \
        CC="/usr/bin/clang -arch $arch" \
        CFLAGS="-O2 -mmacosx-version-min=14.0" \
        OPENSSL_CFLAGS="-I$openssl_dir/include" \
        OPENSSL_LIBS="-L$work_dir/ossl-static -lssl -lcrypto -lpthread" \
        LIBXML2_CFLAGS="-I$sdk/usr/include/libxml2" \
        LIBXML2_LIBS="-lxml2" \
        ./configure --prefix="$work_dir/oc-install" --disable-shared --enable-static \
        --without-gnutls --without-lz4 --without-libproxy --without-stoken --without-gssapi --without-libpcsclite \
        --disable-nls --with-system-cafile=/etc/ssl/cert.pem --with-vpnc-script=/usr/bin/false > configure.log 2>&1
    /usr/bin/make -j "$jobs" AR=/usr/bin/ar RANLIB=/usr/bin/ranlib openconnect > build.log 2>&1
    /usr/bin/make install-sbinPROGRAMS > install.log 2>&1
    cp "$work_dir/oc-install/sbin/openconnect" "$out_dir/bin/openconnect"
)

chmod 755 "$out_dir/bin/openconnect" "$out_dir/bin/ocproxy"

# Verify no non-Apple dylibs are linked
for bin in "$out_dir/bin/openconnect" "$out_dir/bin/ocproxy"; do
    print "=== $bin ==="
    otool -L "$bin"
    if otool -L "$bin" | tail -n +2 | grep -qvE '^\t(/usr/lib/|/System/)'; then
        print -u2 "ERROR: $bin links non-system libraries!"
        exit 1
    fi
done
