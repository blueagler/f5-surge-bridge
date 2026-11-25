#!/bin/zsh
set -euo pipefail

archive_dir="${1:?pass the directory containing both architecture archives}"
source "${0:A:h}/build-common.zsh"
work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT

for arch in arm64 x86_64; do
    ditto -x -k "$archive_dir/UWVPN-macOS-$arch.zip" "$work_dir/$arch"
    codesign --verify --deep --strict "$work_dir/$arch/UWVPN.app"
done
for key in CFBundleShortVersionString CFBundleVersion UWVPNSourceRevision UWVPDistribution; do
    left=$(/usr/libexec/PlistBuddy -c "Print :$key" "$work_dir/arm64/UWVPN.app/Contents/Info.plist" 2>/dev/null) || {
        print -u2 "The arm64 archive is missing $key."
        exit 1
    }
    right=$(/usr/libexec/PlistBuddy -c "Print :$key" "$work_dir/x86_64/UWVPN.app/Contents/Info.plist" 2>/dev/null) || {
        print -u2 "The x86_64 archive is missing $key."
        exit 1
    }
    [[ "$left" == "$right" ]] || {
        print -u2 "The architecture archives disagree about $key."
        exit 1
    }
done

universal="$work_dir/universal/UWVPN.app"
ditto "$work_dir/arm64/UWVPN.app" "$universal"
for license in "$work_dir/x86_64/UWVPN.app/Contents/Resources/Licenses/"**/*(.); do
    intel_licenses="$work_dir/x86_64/UWVPN.app/Contents/Resources/Licenses/"
    relative="${license#$intel_licenses}"
    target="$universal/Contents/Resources/Licenses/$relative"
    if [[ -f "$target" ]]; then
        cmp -- "$license" "$target"
    else
        mkdir -p "${target:h}"
        cp "$license" "$target"
    fi
done
for executable in Contents/MacOS/UWVPN Contents/Resources/bin/{openconnect,tun-socks}; do
    lipo -create "$work_dir/arm64/UWVPN.app/$executable" "$work_dir/x86_64/UWVPN.app/$executable" \
        -output "$universal/$executable"
    architectures=" $(lipo -archs "$universal/$executable") "
    [[ "$architectures" == *' arm64 '* && "$architectures" == *' x86_64 '* ]]
done
uwvpn_sign_app "$universal"
ditto -c -k --sequesterRsrc --keepParent "$universal" "$archive_dir/UWVPN-macOS-universal.zip"
