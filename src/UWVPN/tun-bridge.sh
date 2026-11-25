#!/bin/zsh
set -eu

profile_id="${1:?missing profile id}"
socks_port="${2:?missing socks port}"
rule_stem="${3:-}"
support_dir="$HOME/Library/Application Support/UWVPN"
mkdir -p "$support_dir"

{
    print "profile=${profile_id}"
    print "updated=$(date '+%Y-%m-%d %H:%M:%S')"
    print "ipv4=${INTERNAL_IP4_ADDRESS:-}"
    print "ipv6=${INTERNAL_IP6_ADDRESS:-}"
    print "netmask=${INTERNAL_IP4_NETMASK:-}"
    print "dns=${INTERNAL_IP4_DNS:-}"
    print "domains=${CISCO_DEF_DOMAIN:-}"
    print "split_inc=${CISCO_SPLIT_INC:-0}"
    print "split_exc=${CISCO_SPLIT_EXC:-0}"
} > "$support_dir/${profile_id}-meta.txt"

exec "${0:A:h}/tun-socks" "$socks_port" "$rule_stem"
