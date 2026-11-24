# Code Review Summary & Roadmap

## Issues Found & Fixed (Audit by `gpt-6.2-sol`)

1. **Critical — `tun-bridge.sh` aborted on first split route**: `(( i++ ))` / `(( j++ ))` with `set -e` returned exit code `1` on `0++`, aborting before `exec ocproxy`. Fixed with `i=$((i + 1))` and temp-file cleanup `trap`.
2. **Readiness false positives & port conflicts**: replaced bare TCP connect with pre-launch port-occupancy check + verified SOCKS5 handshake (`0x05 0x01 0x00 -> 0x05 0x00`) + 15s timeout.
3. **Teardown reentrancy & stale callbacks**: eliminated nested `RunLoop.current.run` polling, added monotonic `generation` counters across all async callbacks, and added `applicationShouldTerminate` deferred `SIGHUP` detach.
4. **Relay safety & performance**: added `SIG_IGN` for `SIGPIPE` + `SO_NOSIGPIPE` + `FD_CLOEXEC`, replaced per-`CONNECT` `netstat`/`scutil` forks with `SCDynamicStore` caching, added bounded concurrency (64), half-close `shutdown(SHUT_WR)`, non-blocking multi-address `connect()`, random DNS TXID + connected UDP + bounded compression-pointer parsing + full `198.18.0.0/15` filtering.
5. **WebKit & Keychain robustness**: added `dirty` cookie re-check flag, navigation/renderer failure retry alerts, typed Keychain error handling, removed invented 72h expiry fallback, and switched Launch at Login to `SMAppService.mainApp`.
6. **Portability**: `scripts/build-helpers.sh` now links `openconnect` against static `libssl.a`/`libcrypto.a` and Apple's system `/usr/lib/libxml2.2.dylib`, `/usr/lib/libz.1.dylib`, `/usr/lib/libiconv.2.dylib` — zero Homebrew/nanobrew runtime dylibs.

## Implemented After the Initial Audit

- The gVisor helper supports SOCKS5 `CONNECT` and `UDP ASSOCIATE` for both IP families over `VPNFD`. The physical gateway relay supports `IPV6_BOUND_IF` for IPv6 connections.
- `config.json` supports custom F5 gateways with UW Husky OnNet as the default preset. **Install / Update Surge Module** generates and enables a module using the configured hosts and split rules.

## End-to-End Verification Checklist
- [x] `Campus Only` (`huskyonnet.uw.edu`) WebKit SAML + Duo -> `ocproxy` SOCKS5 -> Surge `UW-Campus` -> `Success!`
- [x] `tun-bridge.sh` verified with 0, 1, and 2 `CISCO_SPLIT_INC`/`EXC` entries
- [x] Portable `openconnect` & `ocproxy` verified with `otool -L` (Apple OS dylibs only)
- [x] Local dual-stack TCP and UDP SOCKS5 round trips and tunnel DNS queries with the gVisor helper
- [ ] Live UDP and IPv6 egress via Husky OnNet and Surge
- [ ] `All Internet` (`huskyonnet-ns.uw.edu`) end-to-end Duo login + campus test + public egress IP check
- [ ] Mac sleep/wake + Ethernet <-> Wi-Fi handoff + 72h expiry re-auth test
