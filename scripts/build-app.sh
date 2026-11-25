#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
arch="${1:-$(uname -m)}"
helpers_dir="${2:-$repo_root/build/helpers-$arch}"
app_out="${3:-$repo_root/dist/UWVPN.app}"
src_dir="$repo_root/src/UWVPN"
source "$repo_root/scripts/build-common.zsh"
min_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$src_dir/Info.plist")

case "$arch" in
    arm64) go_arch=arm64 ;;
    x86_64) go_arch=amd64 ;;
    *) print -u2 "Unsupported macOS architecture: $arch"; exit 1 ;;
esac
if ! command -v go >/dev/null; then
    print -u2 "Go 1.27.3 or newer is required to build tun-socks."
    exit 1
fi
expected_fingerprint=$("$repo_root/scripts/build-helpers.sh" --fingerprint "$arch")
if [[ ! -x "$helpers_dir/bin/openconnect" || ! -f "$helpers_dir/licenses/OpenConnect.txt" || ! -f "$helpers_dir/licenses/OpenSSL.txt" ||
      ! -f "$helpers_dir/fingerprint" || "$(<"$helpers_dir/fingerprint")" != "$expected_fingerprint" ]]; then
    "$repo_root/scripts/build-helpers.sh" "$arch" "$helpers_dir"
fi
helpers_dir="${helpers_dir:A}"
(
    cd "$repo_root/src/tun-socks"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$go_arch" go build -mod=readonly -trimpath -o "$helpers_dir/bin/tun-socks" .
)

rm -rf "$app_out"
mkdir -p "$app_out/Contents/MacOS" "$app_out/Contents/Resources/bin"

cp "$src_dir/Info.plist" "$app_out/Contents/Info.plist"
uwvpn_write_metadata "$app_out/Contents/Info.plist"
cp "$helpers_dir/bin/openconnect" "$app_out/Contents/Resources/bin/openconnect"
cp "$helpers_dir/bin/tun-socks" "$app_out/Contents/Resources/bin/tun-socks"
cp "$src_dir/tun-bridge.sh" "$app_out/Contents/Resources/bin/tun-bridge.sh"
chmod 755 "$app_out/Contents/Resources/bin/"{openconnect,tun-socks,tun-bridge.sh}

licenses_dir="${app_out:A}/Contents/Resources/Licenses"
mkdir -p "$licenses_dir/go"
cp "$helpers_dir/licenses/"{OpenConnect,OpenSSL}.txt "$licenses_dir/"
cp "$repo_root/LICENSE" "$licenses_dir/UWVPN.txt"
(
    cd "$repo_root/src/tun-socks"
    goroot=$(go env GOROOT)
    cp "$goroot/LICENSE" "$licenses_dir/go/"
    if [[ -f "$goroot/PATENTS" ]]; then cp "$goroot/PATENTS" "$licenses_dir/go/"; fi
    CGO_ENABLED=0 GOOS=darwin GOARCH="$go_arch" go list -mod=readonly -deps \
        -f '{{with .Module}}{{if not .Main}}{{.Path}} {{.Dir}}{{end}}{{end}}' . | sort -u |
        while read -r module module_dir; do
            [[ -n "$module_dir" ]] || continue
            mkdir -p "$licenses_dir/$module"
            license=""
            for candidate in LICENSE LICENSE.md LICENSE.txt COPYING; do
                if [[ -f "$module_dir/$candidate" ]]; then
                    license="$candidate"
                    break
                fi
            done
            if [[ -z "$license" ]]; then
                print -u2 "Missing license for $module"
                exit 1
            fi
            cp "$module_dir/$license" "$licenses_dir/$module/"
            for notice in NOTICE PATENTS; do
                if [[ -f "$module_dir/$notice" ]]; then
                    cp "$module_dir/$notice" "$licenses_dir/$module/"
                fi
            done
        done
)

xcrun swiftc -target "${arch}-apple-macos${min_macos}" -swift-version 5 -warnings-as-errors -O \
    -framework AppKit -framework Network -framework WebKit -framework Security -framework ServiceManagement \
    -o "$app_out/Contents/MacOS/UWVPN" \
    "$src_dir/"*.swift(N)

for bin in "$app_out/Contents/MacOS/UWVPN" "$app_out/Contents/Resources/bin/"{openconnect,tun-socks}; do
    if otool -L "$bin" | tail -n +2 | grep -qvE '^[[:space:]]+(/usr/lib/|/System/)'; then
        print -u2 "ERROR: $bin has non-system library dependencies:"
        otool -L "$bin"
        exit 1
    fi
    binary_minimum=$(xcrun vtool -show-build "$bin" | awk '/minos/ { print $2 }')
    if ! awk -v actual="$binary_minimum" -v target="$min_macos" 'BEGIN {
        if (actual !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) exit 1
        split(actual, a, "."); split(target, t, ".")
        for (i = 1; i <= 3; i++) if (a[i]+0 != t[i]+0) exit (a[i]+0 > t[i]+0)
    }'; then
        print -u2 "ERROR: $bin requires macOS $binary_minimum, bundle supports macOS $min_macos"
        exit 1
    fi
done

uwvpn_sign_app "$app_out"
print "Built $uwvpn_mode app $uwvpn_version ($uwvpn_build_number) at $uwvpn_revision: $app_out ($arch)"
