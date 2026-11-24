#!/bin/zsh
set -eu

repo_root="${0:A:h:h}"
arch="${1:-$(uname -m)}"
helpers_dir="${2:-$repo_root/build/helpers-$arch}"
app_out="${3:-$repo_root/dist/UWVPN.app}"
src_dir="$repo_root/src/UWVPN"

if [[ ! -x "$helpers_dir/bin/openconnect" || ! -x "$helpers_dir/bin/ocproxy" ]]; then
    "$repo_root/scripts/build-helpers.sh" "$arch" "$helpers_dir"
fi

rm -rf "$app_out"
mkdir -p "$app_out/Contents/MacOS" "$app_out/Contents/Resources/bin"

cp "$src_dir/Info.plist" "$app_out/Contents/Info.plist"
cp "$helpers_dir/bin/openconnect" "$app_out/Contents/Resources/bin/openconnect"
cp "$helpers_dir/bin/ocproxy" "$app_out/Contents/Resources/bin/ocproxy"
cp "$src_dir/tun-bridge.sh" "$app_out/Contents/Resources/bin/tun-bridge.sh"
chmod 755 "$app_out/Contents/Resources/bin/openconnect" "$app_out/Contents/Resources/bin/ocproxy" "$app_out/Contents/Resources/bin/tun-bridge.sh"

xcrun swiftc -target "${arch}-apple-macos14.0" -swift-version 5 -warnings-as-errors -O \
    -framework AppKit -framework Network -framework WebKit -framework Security -framework ServiceManagement \
    -o "$app_out/Contents/MacOS/UWVPN" \
    "$src_dir/Models.swift" "$src_dir/KeychainStore.swift" "$src_dir/GatewayRelay.swift" \
    "$src_dir/WebLoginWindow.swift" "$src_dir/TunnelController.swift" "$src_dir/AppDelegate.swift" "$src_dir/main.swift"

for bin in "$app_out/Contents/MacOS/UWVPN" "$app_out/Contents/Resources/bin/openconnect" "$app_out/Contents/Resources/bin/ocproxy"; do
    if otool -L "$bin" | tail -n +2 | grep -qvE '^\t(/usr/lib/|/System/)'; then
        print -u2 "ERROR: $bin has non-system library dependencies:"
        otool -L "$bin"
        exit 1
    fi
done

codesign --force --deep --sign - "$app_out"
codesign --verify --deep --strict "$app_out"
print "Built portable app: $app_out ($arch)"
