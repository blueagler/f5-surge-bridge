#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
arch="${1:-$(uname -m)}"
helpers_dir="${2:-$repo_root/build/helpers-$arch}"
app_out="${3:-$repo_root/dist/UWVPN.app}"
src_dir="$repo_root/src/UWVPN"

case "$arch" in
    arm64) go_arch=arm64 ;;
    x86_64) go_arch=amd64 ;;
    *) print -u2 "Unsupported macOS architecture: $arch"; exit 1 ;;
esac
if ! command -v go >/dev/null; then
    print -u2 "Go 1.27.3 or newer is required to build tun-socks."
    exit 1
fi
if [[ ! -x "$helpers_dir/bin/openconnect" ]]; then
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
cp "$helpers_dir/bin/openconnect" "$app_out/Contents/Resources/bin/openconnect"
cp "$helpers_dir/bin/tun-socks" "$app_out/Contents/Resources/bin/tun-socks"
cp "$src_dir/tun-bridge.sh" "$app_out/Contents/Resources/bin/tun-bridge.sh"
cp "$repo_root/surge/uw-vpn.sgmodule.template" "$app_out/Contents/Resources/uw-vpn.sgmodule.template"
chmod 755 "$app_out/Contents/Resources/bin/"{openconnect,tun-socks,tun-bridge.sh}

licenses_dir="${app_out:A}/Contents/Resources/Licenses"
mkdir -p "$licenses_dir/go"
(
    cd "$repo_root/src/tun-socks"
    cp "$(go env GOROOT)/"{LICENSE,PATENTS} "$licenses_dir/go/"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$go_arch" go list -mod=readonly -deps \
        -f '{{with .Module}}{{if not .Main}}{{.Path}} {{.Dir}}{{end}}{{end}}' . | sort -u |
        while read -r module module_dir; do
            [[ -n "$module_dir" ]] || continue
            mkdir -p "$licenses_dir/$module"
            cp "$module_dir/LICENSE" "$licenses_dir/$module/"
            for notice in NOTICE PATENTS; do
                if [[ -f "$module_dir/$notice" ]]; then
                    cp "$module_dir/$notice" "$licenses_dir/$module/"
                fi
            done
        done
)

xcrun swiftc -target "${arch}-apple-macos14.0" -swift-version 5 -warnings-as-errors -O \
    -framework AppKit -framework Network -framework WebKit -framework Security -framework ServiceManagement \
    -o "$app_out/Contents/MacOS/UWVPN" \
    "$src_dir/Models.swift" "$src_dir/KeychainStore.swift" "$src_dir/GatewayRelay.swift" \
    "$src_dir/WebLoginWindow.swift" "$src_dir/TunnelController.swift" "$src_dir/SurgeModule.swift" \
    "$src_dir/AppDelegate.swift" "$src_dir/main.swift"

for bin in "$app_out/Contents/MacOS/UWVPN" "$app_out/Contents/Resources/bin/"{openconnect,tun-socks}; do
    if otool -L "$bin" | tail -n +2 | grep -qvE '^[[:space:]]+(/usr/lib/|/System/)'; then
        print -u2 "ERROR: $bin has non-system library dependencies:"
        otool -L "$bin"
        exit 1
    fi
done

codesign --force --deep --sign - "$app_out"
codesign --verify --deep --strict "$app_out"
print "Built portable app: $app_out ($arch)"
