#!/bin/zsh
set -eu

repo_root="${0:A:h:h}"
arch="${1:-$(uname -m)}"
out_dir="${2:-$repo_root/build/helpers-$arch}"
out_dir="${out_dir:A}"
work_dir="${repo_root}/build/src-$arch"

mkdir -p "$out_dir/bin" "$work_dir/tools/bin" "$work_dir/ossl-static"

OPENCONNECT_VER="9.21"
OPENCONNECT_SHA256="5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58"
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

# 2. Build portable openconnect (static OpenSSL + Apple system libxml2/zlib/iconv)
fetch_and_verify \
    "https://www.infradead.org/openconnect/download/openconnect-${OPENCONNECT_VER}.tar.gz" \
    "openconnect-${OPENCONNECT_VER}.tar.gz" \
    "$OPENCONNECT_SHA256"
/usr/bin/tar -xzf "openconnect-${OPENCONNECT_VER}.tar.gz"
(
    cd "openconnect-${OPENCONNECT_VER}"
    # macOS added strchrnul in 15.4. Use OpenConnect's fallback for macOS 14.
    env AR=/usr/bin/ar RANLIB=/usr/bin/ranlib PKG_CONFIG="$pkgconf_bin" \
        CC="/usr/bin/clang -arch $arch" \
        CFLAGS="-O2 -mmacosx-version-min=14.0" \
        ac_cv_func_strchrnul=no \
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

bin="$out_dir/bin/openconnect"
chmod 755 "$bin"

# Verify no non-Apple dylibs are linked
print "=== $bin ==="
otool -L "$bin"
if otool -L "$bin" | tail -n +2 | grep -qvE '^[[:space:]]+(/usr/lib/|/System/)'; then
    print -u2 "ERROR: $bin links non-system libraries!"
    exit 1
fi
