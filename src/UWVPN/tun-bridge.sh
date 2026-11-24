#!/bin/zsh
set -eu

profile_id="${1:?missing profile id}"
socks_port="${2:?missing socks port}"
rule_stem="${3:-}"
support_dir="$HOME/Library/Application Support/UWVPN"
mkdir -p "$support_dir"

tmp_rules=""
tmp_exc=""
cleanup_tmp() {
    rm -f -- "$tmp_rules" "$tmp_exc" 2>/dev/null || true
}
trap cleanup_tmp EXIT

print_cidrs() {
    local prefix="$1" rule_type="$2" count_var="${1}" i addr_var mask_var addr masklen
    local count="${(P)count_var:-0}"
    for ((i = 0; i < count; i++)); do
        addr_var="${prefix}_${i}_ADDR"
        mask_var="${prefix}_${i}_MASKLEN"
        addr="${(P)addr_var:-}"
        masklen="${(P)mask_var:-}"
        if [[ -n "$addr" && -n "$masklen" ]]; then
            print -r -- "$rule_type,${addr}/${masklen},no-resolve"
        fi
    done
}

if [[ -n "$rule_stem" ]]; then
    tmp_rules=$(mktemp "$support_dir/${rule_stem}-split.XXXXXXXX")
    {
        print "# Derived from F5 BIG-IP protocol options on $(date '+%Y-%m-%d %H:%M:%S')"
        if [[ -n "${CISCO_DEF_DOMAIN:-}" ]]; then
            for dom in ${=CISCO_DEF_DOMAIN}; do
                print -r -- "DOMAIN-SUFFIX,${dom}"
            done
        fi
        print_cidrs CISCO_SPLIT_INC IP-CIDR
        print_cidrs CISCO_IPV6_SPLIT_INC IP-CIDR6
    } > "$tmp_rules"

    tmp_exc=$(mktemp "$support_dir/${rule_stem}-exclude.XXXXXXXX")
    {
        print "# Derived from F5 BIG-IP split-exclude options on $(date '+%Y-%m-%d %H:%M:%S')"
        print_cidrs CISCO_SPLIT_EXC IP-CIDR
        print_cidrs CISCO_IPV6_SPLIT_EXC IP-CIDR6
    } > "$tmp_exc"

    mv "$tmp_exc" "$support_dir/${rule_stem}-exclude.list"
    mv "$tmp_rules" "$support_dir/${rule_stem}-split.list"
    tmp_exc=""
    tmp_rules=""
fi

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

trap - EXIT
exec "${0:A:h}/tun-socks" "$socks_port"
