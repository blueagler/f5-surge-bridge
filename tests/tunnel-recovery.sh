#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
app="$work/Health.app/Contents"
helpers="$app/Resources/bin"
mkdir -p "$app/MacOS" "$helpers"
cp "$root/src/UWVPN/Info.plist" "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Health' \
    -c 'Set :CFBundleIdentifier com.blueagle.uwvpn.health-fixture' "$app/Info.plist"
cp "$root/tests/fake-openconnect.py" "$helpers/openconnect"
touch "$helpers/"{tun-socks,tun-bridge.sh}
chmod +x "$helpers/"{openconnect,tun-socks,tun-bridge.sh}
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
src="$root/src/UWVPN"
xcrun swiftc -swift-version 5 -warnings-as-errors -o "$app/MacOS/Health" \
    "$root/tests/TunnelRecovery.swift" \
    "$src/"{Models,GatewayRelay,SurgeModule,WebLoginWindow,TunnelController}.swift
"$app/MacOS/Health" "$work/pids" "$port"

xcrun swiftc -swift-version 5 -warnings-as-errors -o "$work/HealthLifecycle" \
    "$root/tests/TunnelHealthLogout.swift" \
    "$src/"{Models,GatewayRelay,SurgeModule,WebLoginWindow,TunnelController}.swift
"$work/HealthLifecycle"

"$app/MacOS/Health" "$work/health-pids" "$port" --health
