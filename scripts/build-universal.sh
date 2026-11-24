#!/bin/zsh
set -euo pipefail

archive_dir="${1:?pass the directory containing both architecture archives}"
work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT

for arch in arm64 x86_64; do
    ditto -x -k "$archive_dir/UWVPN-macOS-$arch.zip" "$work_dir/$arch"
    codesign --verify --deep --strict "$work_dir/$arch/UWVPN.app"
done

universal="$work_dir/universal/UWVPN.app"
ditto "$work_dir/arm64/UWVPN.app" "$universal"
for executable in Contents/MacOS/UWVPN Contents/Resources/bin/{openconnect,tun-socks}; do
    lipo -create "$work_dir/arm64/UWVPN.app/$executable" "$work_dir/x86_64/UWVPN.app/$executable" \
        -output "$universal/$executable"
    architectures=" $(lipo -archs "$universal/$executable") "
    [[ "$architectures" == *' arm64 '* && "$architectures" == *' x86_64 '* ]]
done
codesign --force --deep --sign - "$universal"
codesign --verify --deep --strict "$universal"
ditto -c -k --sequesterRsrc --keepParent "$universal" "$archive_dir/UWVPN-macOS-universal.zip"
