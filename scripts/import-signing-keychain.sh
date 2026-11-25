#!/bin/zsh
set -euo pipefail

: "${UWVPN_DEVELOPER_ID_P12:?Set the base64-encoded Developer ID certificate.}"
: "${UWVPN_DEVELOPER_ID_P12_PASSWORD:?Set the certificate password.}"
: "${UWVPN_CI_KEYCHAIN_PASSWORD:?Set a temporary keychain password.}"
keychain="${UWVPN_KEYCHAIN:-${RUNNER_TEMP:?Set RUNNER_TEMP or UWVPN_KEYCHAIN}/release.keychain-db}"
certificate=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/uwvpn-certificate.XXXXXXXX")
trap 'rm -f -- "$certificate"' EXIT

security create-keychain -p "$UWVPN_CI_KEYCHAIN_PASSWORD" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$UWVPN_CI_KEYCHAIN_PASSWORD" "$keychain"
print -rn -- "$UWVPN_DEVELOPER_ID_P12" | /usr/bin/base64 --decode > "$certificate"
security import "$certificate" -P "$UWVPN_DEVELOPER_ID_P12_PASSWORD" -k "$keychain" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -k "$UWVPN_CI_KEYCHAIN_PASSWORD" "$keychain"
security list-keychains -d user -s "$keychain"
rm -f -- "$certificate"
if [[ -n "${GITHUB_ENV:-}" ]]; then
    print "UWVPN_KEYCHAIN=$keychain" >> "$GITHUB_ENV"
fi
