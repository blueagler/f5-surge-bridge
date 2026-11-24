# Architecture: F5 BIG-IP SAML -> OpenConnect -> SOCKS5 -> Surge

## Why BIG-IP Edge Client broke Surge Enhanced Mode

On macOS, Surge Enhanced Mode creates a virtual interface (`utun`) and uses `198.18.0.0/15` as its fake-IP DNS responder and mapping pool (`198.18.0.2`). When `BIG-IP Edge Client` (`svpn`) connected to UW Husky OnNet, it classified `198.18.0.1` as a vulnerable local IP and patched `198.18.0.0/15` into the F5 `utun` routing table, breaking Surge DNS and all fake-IP connections.

F5 Access for macOS (`2.1.1`) uses Network Extension (`PacketTunnel` + `DNSProxy`) and can coexist with Surge Enhanced Mode, **but** both official F5 clients still install system `utun` routes (`10.0.0.0/8`, `172.16.0.0/12`, etc.) and cannot act as a selective outbound node inside Surge.

## Userspace SOCKS5 Bridge (`UWVPN.app`)

`UWVPN.app` turns F5 BIG-IP APM (including SAML + Duo MFA) into a single local SOCKS5 node (`127.0.0.1:11080`) with **zero `utun` interfaces and zero macOS routing table changes**:

1. **Physical-NIC HTTP `CONNECT` Relay (`GatewayRelay.swift`)**
   - Listens on `127.0.0.1:<ephemeral>`.
   - Allows `CONNECT` only to configured F5 gateway hosts (`huskyonnet-ns.uw.edu:443`, `huskyonnet.uw.edu:443`).
   - Reads active physical `en*` interface and DHCP DNS servers directly via `SystemConfiguration` (`SCDynamicStore`).
   - Queries A and AAAA via DNS sockets bound to the physical NIC. System resolver fallback rejects Surge's IPv4 and IPv6 fake addresses.
   - Binds outbound TCP sockets to the physical NIC with `IP_BOUND_IF` for IPv4 and `IPV6_BOUND_IF` for IPv6.

2. **WebKit SAML + Duo Login (`WebLoginWindow.swift`)**
   - Uses a persistent per-gateway `WKWebsiteDataStore(forIdentifier:)` so UW IdP / Duo trust cookies survive restarts.
   - Sends a Linux browser `User-Agent` to bypass UW APM's macOS browser block and enter the SAML + Duo flow directly.
   - Watches `WKHTTPCookieStore` for `MRHSession` + `F5_ST` (rejecting `"deleted"` sentinels) and persists them in macOS Keychain (`KeychainStore.swift`).

3. **OpenConnect + gVisor Userspace Tunnel (`TunnelController.swift`, `tun-bridge.sh`, `src/tun-socks/`)**
   - Passes the cookie via `--cookie-on-stdin` (never argv/disk).
   - Runs `openconnect --protocol=f5 --no-dtls --script-tun`. Its script starts `tun-socks`, which exchanges raw IP datagrams with OpenConnect over `VPNFD`.
   - `tun-socks` exposes loopback SOCKS5 `CONNECT` and `UDP ASSOCIATE`. It resolves SOCKS5 destinations through F5-provided DNS and forwards them through the userspace IPv4/IPv6 stack.
   - `tun-bridge.sh` uses server-provided IPv4 and IPv6 includes/excludes and `CISCO_DEF_DOMAIN` to generate Surge rules for the configured split gateway.
   - **Clean Detach (`SIGHUP`) vs Logout (`SIGTERM`)**: normal disconnect and app quit send `SIGHUP` (`OC_CMD_DETACH`), preserving the server session so cached Keychain credentials reconnect without Duo until `F5_ST` expires (~72h). Explicit **Sign Out** sends `SIGTERM` / `/vdesk/hangup.php3?hangup_error=1` and wipes Keychain + WebKit data.
   - **Keepalive**: periodically requests `/vdesk/timeoutagent-i.php` over the physical-NIC relay to refresh session state and detect server hangup.

4. **Surge Integration (Single Node, Two Effective Modes)**
   - **Normal (`Rule` mode)**: `uw-vpn.sgmodule` routes `uw-split.list` through `UW-Campus` (`fallback, UW-VPN, DIRECT`), while everything else stays on your normal Surge policies / Tailscale / `DIRECT`.
   - **Full Campus Egress (`Global Proxy` -> `UW-VPN`)**: because `UWVPN.app` defaults to `huskyonnet-ns.uw.edu`, switching Surge to Global Proxy sends all traffic out through UW's public egress IP without launching a second VPN tunnel.
