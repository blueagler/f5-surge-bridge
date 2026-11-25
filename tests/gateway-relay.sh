#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -o "$work/check" \
    "$root/tests/GatewayRelayRecovery.swift" "$root/src/UWVPN/"{GatewayRelay,Models}.swift
"$work/check" "$work/config.json"
