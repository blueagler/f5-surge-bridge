#!/bin/zsh
set -eu

repo_root="${0:A:h:h}"
support_dir="$HOME/Library/Application Support/UWVPN"
surge_docs="$HOME/Library/Mobile Documents/iCloud~com~nssurge~inc/Documents"
if [[ ! -d "$surge_docs" ]]; then
    surge_docs="$HOME/Library/Application Support/Surge/Profiles"
fi

mkdir -p "$support_dir" "$surge_docs"
if [[ ! -f "$support_dir/uw-split.list" ]]; then
    print "# Populated automatically from F5 BIG-IP protocol options on Campus Only connect" > "$support_dir/uw-split.list"
fi
if [[ ! -f "$support_dir/uw-exclude.list" ]]; then
    print "# Populated automatically from F5 BIG-IP split-exclude options" > "$support_dir/uw-exclude.list"
fi

sed "s|__SUPPORT_DIR__|$support_dir|g" "$repo_root/surge/uw-vpn.sgmodule.template" > "$surge_docs/uw-vpn.sgmodule"
print "Installed Surge module to: $surge_docs/uw-vpn.sgmodule"
