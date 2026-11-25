#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
if [[ "${1:-}" == --fingerprint ]]; then
    {
        /bin/cat "$repo_root/scripts/build-helpers.sh" "$repo_root/src/UWVPN/Info.plist"
        print -r -- "${2:?missing architecture}"
        xcrun swiftc --version
        /usr/bin/clang --version
        xcrun --show-sdk-version
        xcrun --show-sdk-path
        if command -v pkgconf >/dev/null; then
            pkgconf --version
        elif command -v pkg-config >/dev/null; then
            pkg-config --version
        fi
    } | /usr/bin/shasum -a 256 | /usr/bin/cut -d ' ' -f 1
    exit
fi
arch="${1:-$(uname -m)}"
out_dir="${2:-$repo_root/build/helpers-$arch}"
out_dir="${out_dir:A}"
work_dir="${repo_root}/build/src-$arch"

mkdir -p "$out_dir/bin" "$out_dir/licenses" "$work_dir/empty-pkgconfig"

OPENCONNECT_VER="9.21"
OPENCONNECT_SHA256="5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58"
OPENSSL_VER="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
PKGCONF_VER="3.0.11"
PKGCONF_SHA256="d0cd841bc8e55b9da888106c00dc256d05b7d1d8e5a46f4be4eb4c5125bd2dc4"

sdk=$(xcrun --show-sdk-path)
unset CPPFLAGS LDFLAGS CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH MACOSX_DEPLOYMENT_TARGET
export SDKROOT="$sdk"
min_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$repo_root/src/UWVPN/Info.plist")
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

cd "$work_dir"
source_dir=$(mktemp -d "$work_dir/sources.XXXXXXXX")
trap 'rm -rf -- "$source_dir"' EXIT

openssl_dir="$source_dir/openssl-${OPENSSL_VER}"
case "$arch" in
    arm64) openssl_target=darwin64-arm64-cc ;;
    x86_64) openssl_target=darwin64-x86_64-cc ;;
    *) print -u2 "Unsupported macOS architecture: $arch"; exit 1 ;;
esac
fetch_and_verify \
    "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz" \
    "openssl-${OPENSSL_VER}.tar.gz" "$OPENSSL_SHA256"
/usr/bin/tar -xzf "openssl-${OPENSSL_VER}.tar.gz" -C "$source_dir"
(
    cd "$openssl_dir"
    logged configure.log env CC=/usr/bin/clang /usr/bin/perl Configure "$openssl_target" no-shared no-tests no-apps \
        "-mmacosx-version-min=$min_macos" "-isysroot$sdk"
    logged build.log /usr/bin/make -j "$jobs" AR=/usr/bin/ar 'RANLIB=/usr/bin/ranlib -c' build_libs
)

if ! pkgconf_bin=$(command -v pkgconf || command -v pkg-config); then
    pkgconf_bin="$work_dir/tools/bin/pkgconf"
    if [[ ! -x "$pkgconf_bin" ]]; then
        fetch_and_verify \
            "https://distfiles.ariadne.space/pkgconf/pkgconf-${PKGCONF_VER}.tar.xz" \
            "pkgconf-${PKGCONF_VER}.tar.xz" "$PKGCONF_SHA256"
        /usr/bin/tar -xf "pkgconf-${PKGCONF_VER}.tar.xz" -C "$source_dir"
        (
            cd "$source_dir/pkgconf-${PKGCONF_VER}"
            logged configure.log ./configure --prefix="$work_dir/tools"
            logged build.log /usr/bin/make -j "$jobs"
            logged install.log /usr/bin/make install
        )
    fi
fi

# Build portable OpenConnect using static OpenSSL and macOS SDK libraries.
fetch_and_verify \
    "https://www.infradead.org/openconnect/download/openconnect-${OPENCONNECT_VER}.tar.gz" \
    "openconnect-${OPENCONNECT_VER}.tar.gz" \
    "$OPENCONNECT_SHA256"
/usr/bin/tar -xzf "openconnect-${OPENCONNECT_VER}.tar.gz" -C "$source_dir"
(
    cd "$source_dir/openconnect-${OPENCONNECT_VER}"
    configure_arch=()
    if [[ "$arch" != "$(uname -m)" ]]; then
        build_triplet=$(/bin/sh ./config.guess)
        host_cpu="$arch"
        if [[ "$arch" == arm64 ]]; then host_cpu=aarch64; fi
        configure_arch=("--build=$build_triplet" "--host=$host_cpu-apple-darwin")
    fi
    # Keep runner-installed packages out of the app's runtime dependencies.
    logged configure.log env AR=/usr/bin/ar RANLIB=/usr/bin/ranlib PKG_CONFIG="$pkgconf_bin" \
        PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$work_dir/empty-pkgconfig" \
        CC="/usr/bin/clang -arch $arch" \
        CFLAGS="-O2 -mmacosx-version-min=$min_macos -isysroot $sdk" \
        OPENSSL_CFLAGS="-I$openssl_dir/include" \
        OPENSSL_LIBS="-L$openssl_dir -lssl -lcrypto -lpthread" \
        LIBXML2_CFLAGS="-I$sdk/usr/include/libxml2" \
        LIBXML2_LIBS="-lxml2" \
        ZLIB_CFLAGS="-I$sdk/usr/include" \
        ZLIB_LIBS="-lz" \
        ./configure "${configure_arch[@]}" --disable-shared --enable-static \
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
cp "$source_dir/openconnect-${OPENCONNECT_VER}/COPYING.LGPL" "$out_dir/licenses/OpenConnect.txt"
cp "$openssl_dir/LICENSE.txt" "$out_dir/licenses/OpenSSL.txt"
"$repo_root/scripts/build-helpers.sh" --fingerprint "$arch" > "$out_dir/fingerprint"
