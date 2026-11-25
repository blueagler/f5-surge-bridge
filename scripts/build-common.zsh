#!/bin/zsh
set -euo pipefail

uwvpn_repo_root="${(%):-%x}"
uwvpn_repo_root="${uwvpn_repo_root:A:h:h}"
uwvpn_mode="${UWVPN_BUILD_MODE:-adhoc}"
uwvpn_revision="${UWVPN_COMMIT:-$(git -C "$uwvpn_repo_root" rev-parse HEAD)}"
uwvpn_sign_identity="-"
uwvpn_build_number=$(git -C "$uwvpn_repo_root" rev-list --count HEAD)

if [[ ! "$uwvpn_revision" =~ '^[0-9a-f]{40}$' ]]; then
    print -u2 "UWVPN_COMMIT must be a full lowercase Git revision."
    exit 1
fi
if [[ "$uwvpn_mode" != adhoc && "$uwvpn_mode" != release ]]; then
    print -u2 "UWVPN_BUILD_MODE must be adhoc or release."
    exit 1
fi
uwvpn_base_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$uwvpn_repo_root/src/UWVPN/Info.plist")
uwvpn_version="$uwvpn_base_version"
uwvpn_dirty=false
if [[ -n "$(git -C "$uwvpn_repo_root" status --porcelain)" ]]; then
    if [[ "$uwvpn_mode" == release ]]; then
        print -u2 "Public releases require a clean checkout."
        exit 1
    fi
    uwvpn_dirty=true
fi
if [[ "$uwvpn_mode" == release ]]; then
    uwvpn_tag="${UWVPN_RELEASE_TAG:?Public releases require UWVPN_RELEASE_TAG.}"
    if [[ ! "$uwvpn_tag" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
        print -u2 "Release tags must use vMAJOR.MINOR.PATCH."
        exit 1
    fi
    if [[ "$(git -C "$uwvpn_repo_root" rev-parse HEAD)" != "$uwvpn_revision" || \
          "$(git -C "$uwvpn_repo_root" rev-parse "refs/tags/$uwvpn_tag^{commit}" 2>/dev/null)" != "$uwvpn_revision" ]]; then
        print -u2 "The release tag and UWVPN_COMMIT must match the checkout."
        exit 1
    fi
    uwvpn_build_number="${UWVPN_BUILD_NUMBER:?Public releases require UWVPN_BUILD_NUMBER.}"
    if [[ "$uwvpn_build_number" != <-> || "$uwvpn_build_number" == 0* ]]; then
        print -u2 "UWVPN_BUILD_NUMBER must be a positive decimal integer."
        exit 1
    fi
    uwvpn_sign_identity="${UWVPN_SIGN_IDENTITY:?Public releases require a Developer ID Application identity.}"
    if [[ "$uwvpn_sign_identity" != "Developer ID Application: "* ]]; then
        print -u2 "Public releases require a Developer ID Application identity."
        exit 1
    fi
    uwvpn_version="${uwvpn_tag#v}"
fi

uwvpn_write_metadata() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $uwvpn_version" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $uwvpn_build_number" "$plist"
    /usr/libexec/PlistBuddy -c "Add :UWVPNSourceRevision string $uwvpn_revision" "$plist"
    /usr/libexec/PlistBuddy -c "Add :UWVPNDistribution string $uwvpn_mode" "$plist"
    /usr/libexec/PlistBuddy -c "Add :UWVPNSourceDirty bool $uwvpn_dirty" "$plist"
}

uwvpn_verify_identity() {
    local app="$1"
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :UWVPNSourceRevision' "$app/Contents/Info.plist" 2>/dev/null)" != "$uwvpn_revision" || \
          "$(/usr/libexec/PlistBuddy -c 'Print :UWVPNDistribution' "$app/Contents/Info.plist" 2>/dev/null)" != "$uwvpn_mode" ]]; then
        print -u2 "The app build identity does not match this build."
        exit 1
    fi
}

uwvpn_sign_app() {
    local app="$1"
    uwvpn_verify_identity "$app"
    if [[ "$uwvpn_mode" == adhoc ]]; then
        codesign --force --deep --sign - --timestamp=none "$app"
    else
        local executable
        local -a keychain_args
        if [[ -n "${UWVPN_KEYCHAIN:-}" ]]; then
            keychain_args=(--keychain "$UWVPN_KEYCHAIN")
        fi
        for executable in "$app/Contents/MacOS/UWVPN" "$app/Contents/Resources/bin/"*(N.x); do
            codesign --force --sign "$uwvpn_sign_identity" --options runtime --timestamp "${keychain_args[@]}" "$executable"
        done
        codesign --force --sign "$uwvpn_sign_identity" --options runtime --timestamp "${keychain_args[@]}" "$app"
        local signature
        signature=$(codesign -dvv "$app" 2>&1)
        if [[ "$signature" != *"Authority=$uwvpn_sign_identity"* || "$signature" != *"flags=0x10000(runtime)"* ]]; then
            print -u2 "The app must have the requested Developer ID and hardened runtime."
            exit 1
        fi
    fi
    codesign --verify --deep --strict "$app"
}
