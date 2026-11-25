#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -o "$work/GatewayRouting" \
    "$root/tests/GatewayRouting.swift" \
    "$root/src/UWVPN/Models.swift" "$root/src/UWVPN/SurgeModule.swift"
HOME="$work/home" "$work/GatewayRouting" "$work/fixture"
