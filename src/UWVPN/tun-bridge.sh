#!/bin/zsh
set -eu

profile_id="${1:?missing profile id}"
socks_port="${2:?missing socks port}"
ocproxy_bin="${0:A:h}/ocproxy"
support_dir="$HOME/Library/Application Support/UWVPN"
mkdir -p "$support_dir"

tmp_rules=""
tmp_exc=""
cleanup_tmp() {
    rm -f -- "$tmp_rules" "$tmp_exc" 2>/dev/null || true
}
trap cleanup_tmp EXIT

if [[ "$profile_id" == "campus" ]]; then
    tmp_rules=$(mktemp "$support_dir/uw-split.XXXXXXXX")
    {
        print "# Derived from F5 BIG-IP protocol options on $(date '+%Y-%m-%d %H:%M:%S')"
        if [[ -n "${CISCO_DEF_DOMAIN:-}" ]]; then
            for dom in ${=CISCO_DEF_DOMAIN}; do
                print "DOMAIN-SUFFIX,${dom}"
            done
        fi
        inc_count="${CISCO_SPLIT_INC:-0}"
        i=0
        while (( i < inc_count )); do
            addr_var="CISCO_SPLIT_INC_${i}_ADDR"
            mask_var="CISCO_SPLIT_INC_${i}_MASKLEN"
            addr="${(P)addr_var:-}"
            masklen="${(P)mask_var:-}"
            if [[ -n "$addr" && -n "$masklen" ]]; then
                print "IP-CIDR,${addr}/${masklen},no-resolve"
            fi
            i=$((i + 1))
        done
    } > "$tmp_rules"

    tmp_exc=$(mktemp "$support_dir/uw-exclude.XXXXXXXX")
    {
        print "# Derived from F5 BIG-IP split-exclude options on $(date '+%Y-%m-%d %H:%M:%S')"
        exc_count="${CISCO_SPLIT_EXC:-0}"
        j=0
        while (( j < exc_count )); do
            addr_var="CISCO_SPLIT_EXC_${j}_ADDR"
            mask_var="CISCO_SPLIT_EXC_${j}_MASKLEN"
            addr="${(P)addr_var:-}"
            masklen="${(P)mask_var:-}"
            if [[ -n "$addr" && -n "$masklen" ]]; then
                print "IP-CIDR,${addr}/${masklen},no-resolve"
            fi
            j=$((j + 1))
        done
    } > "$tmp_exc"

    mv "$tmp_exc" "$support_dir/uw-exclude.list"
    mv "$tmp_rules" "$support_dir/uw-split.list"
    tmp_exc=""
    tmp_rules=""
fi

{
    print "profile=${profile_id}"
    print "updated=$(date '+%Y-%m-%d %H:%M:%S')"
    print "ipv4=${INTERNAL_IP4_ADDRESS:-}"
    print "netmask=${INTERNAL_IP4_NETMASK:-}"
    print "dns=${INTERNAL_IP4_DNS:-}"
    print "domains=${CISCO_DEF_DOMAIN:-}"
    print "split_inc=${CISCO_SPLIT_INC:-0}"
    print "split_exc=${CISCO_SPLIT_EXC:-0}"
} > "$support_dir/${profile_id}-meta.txt"

trap - EXIT
exec "$ocproxy_bin" -D "$socks_port" -k 15
