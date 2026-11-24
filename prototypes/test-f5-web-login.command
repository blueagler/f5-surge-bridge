#!/bin/zsh
set -eu

cd -- "${0:A:h}"
build='/private/var/folders/jp/zbh5f56j5x1dtx__9n1r_58h0000gn/T/opencode/openconnect-test.TaIUAXTg'
port_file=$(mktemp "$build/relay-port.XXXXXXXX")
python3 f5-login-gateway.py auto > "$port_file" &
relay_pid=$!
cleanup() {
    kill "$relay_pid" 2>/dev/null || true
    wait "$relay_pid" 2>/dev/null || true
    rm -f -- "$port_file"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

for attempt in {1..30}; do
    [[ -s "$port_file" ]] && break
    kill -0 "$relay_pid" 2>/dev/null || break
    sleep 0.1
done
if [[ ! -s "$port_file" ]]; then
    print -u2 'The UW gateway relay did not start.'
    exit 1
fi

IFS= read -r port < "$port_file"
"$build/f5-web-login" "$build/openconnect-9.21/openconnect" https://huskyonnet.uw.edu/ "$port" "$build/ocproxy" 11080
