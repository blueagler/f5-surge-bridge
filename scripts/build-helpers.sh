#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
arch="${1:-$(uname -m)}"
out_dir="${2:-$repo_root/build/helpers-$arch}"
out_dir="${out_dir:A}"
work_dir="${repo_root}/build/src-$arch"

mkdir -p "$out_dir/bin" "$work_dir/ossl-static"

OPENCONNECT_VER="9.21"
OPENCONNECT_SHA256="5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58"
OPENSSL_VER="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"

sdk=$(xcrun --show-sdk-path)
jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

fetch_and_verify() {
    local url="$1" dest="$2" expected="$3"
    if [[ -f "$dest" ]] && printf '%s  %s\n' "$expected" "$dest" | /usr/bin/shasum -a 256 -c; then
        return 0
    fi
    /usr/bin/curl -fLsS --retry 3 --connect-timeout 10 --max-time 60 -o "$dest.part" "$url"
    printf '%s  %s\n' "$expected" "$dest.part" | /usr/bin/shasum -a 256 -c
    mv -f "$dest.part" "$dest"
}

logged() {
    local log="$1"
    shift
    "$@" > "$log" 2>&1 || { tail -n 80 "$log" >&2; return 1; }
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

cd "$work_dir"

if [[ "${UWVPN_BUILD_OPENSSL:-0}" != 1 ]] && openssl_dir=$(find_openssl_prefix); then
    print "Using OpenSSL at $openssl_dir"
else
    openssl_dir="$work_dir/openssl-install"
    case "$arch" in
        arm64) openssl_target=darwin64-arm64-cc ;;
        x86_64) openssl_target=darwin64-x86_64-cc ;;
        *) print -u2 "Unsupported macOS architecture: $arch"; exit 1 ;;
    esac
    fetch_and_verify \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz" \
        "openssl-${OPENSSL_VER}.tar.gz" "$OPENSSL_SHA256"
    /usr/bin/tar -xzf "openssl-${OPENSSL_VER}.tar.gz"
    (
        cd "openssl-${OPENSSL_VER}"
        logged configure.log /usr/bin/perl Configure "$openssl_target" no-shared no-tests no-apps \
            -mmacosx-version-min=14.0 --prefix="$openssl_dir"
        logged build.log /usr/bin/make -j "$jobs" AR=/usr/bin/ar 'RANLIB=/usr/bin/ranlib -c' build_libs
        logged install.log /usr/bin/make AR=/usr/bin/ar 'RANLIB=/usr/bin/ranlib -c' install_dev
    )
fi
ln -sf "$openssl_dir/lib/libssl.a" "$work_dir/ossl-static/libssl.a"
ln -sf "$openssl_dir/lib/libcrypto.a" "$work_dir/ossl-static/libcrypto.a"

# Build portable OpenConnect using static OpenSSL and macOS SDK libraries.
fetch_and_verify \
    "https://www.infradead.org/openconnect/download/openconnect-${OPENCONNECT_VER}.tar.gz" \
    "openconnect-${OPENCONNECT_VER}.tar.gz" \
    "$OPENCONNECT_SHA256"
/usr/bin/tar -xzf "openconnect-${OPENCONNECT_VER}.tar.gz"
(
    cd "openconnect-${OPENCONNECT_VER}"
    # Disable host pkg-config discovery and use the strchrnul fallback for macOS 14.
    logged configure.log env AR=/usr/bin/ar RANLIB=/usr/bin/ranlib PKG_CONFIG=/usr/bin/false \
        CC="/usr/bin/clang -arch $arch" \
        CFLAGS="-O2 -mmacosx-version-min=14.0" \
        ac_cv_func_strchrnul=no \
        OPENSSL_CFLAGS="-I$openssl_dir/include" \
        OPENSSL_LIBS="-L$work_dir/ossl-static -lssl -lcrypto -lpthread" \
        LIBXML2_CFLAGS="-I$sdk/usr/include/libxml2" \
        LIBXML2_LIBS="-lxml2" \
        ZLIB_CFLAGS="-I$sdk/usr/include" \
        ZLIB_LIBS="-lz" \
        ./configure --disable-shared --enable-static \
        --without-gnutls --without-lz4 --without-libproxy --without-stoken --without-gssapi --without-libpcsclite \
        --disable-nls --with-system-cafile=/etc/ssl/cert.pem --with-vpnc-script=/usr/bin/false
    logged build.log /usr/bin/make -j "$jobs" AR=/usr/bin/ar RANLIB=/usr/bin/ranlib openconnect
    cp openconnect "$out_dir/bin/openconnect"
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
