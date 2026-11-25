#!/bin/zsh
set -euo pipefail

archive_dir="${1:?pass the directory containing the signed app archives}"
source "${0:A:h}/build-common.zsh"
if [[ "$uwvpn_mode" != release ]]; then
    print -u2 "Notarization requires UWVPN_BUILD_MODE=release."
    exit 1
fi
: "${UWVPN_NOTARY_PROFILE:?Set UWVPN_NOTARY_PROFILE to a notarytool keychain profile.}"
keychain_args=()
if [[ -n "${UWVPN_NOTARY_KEYCHAIN:-}" ]]; then
    keychain_args=(--keychain "$UWVPN_NOTARY_KEYCHAIN")
fi

app_dir=""
final_dir=""
trap 'rm -rf -- "$app_dir" "$final_dir"' EXIT
for arch in arm64 x86_64 universal; do
    archive="$archive_dir/UWVPN-macOS-$arch.zip"
    [[ -f "$archive" ]] || { print -u2 "Missing signed archive: $archive"; exit 1; }
    app_dir=$(mktemp -d)
    ditto -x -k "$archive" "$app_dir"
    app="$app_dir/UWVPN.app"
    uwvpn_verify_identity "$app"
    codesign --verify --deep --strict "$app"
    notary_archive="$app_dir/UWVPN.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$notary_archive"
    xcrun notarytool submit "$notary_archive" --keychain-profile "$UWVPN_NOTARY_PROFILE" \
        "${keychain_args[@]}" --wait --timeout 30m
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=4 "$app"
    python3 "$uwvpn_repo_root/tests/packaged-tunnel.py" "$app"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$archive.new"
    rm -rf "$app_dir"
    mv -f "$archive.new" "$archive"
    final_dir=$(mktemp -d)
    ditto -x -k "$archive" "$final_dir"
    xcrun stapler validate "$final_dir/UWVPN.app"
    spctl --assess --type execute --verbose=4 "$final_dir/UWVPN.app"
    codesign --verify --deep --strict "$final_dir/UWVPN.app"
    python3 "$uwvpn_repo_root/tests/packaged-tunnel.py" "$final_dir/UWVPN.app"
    rm -rf "$final_dir"
    print "Notarized and stapled $archive"
done
