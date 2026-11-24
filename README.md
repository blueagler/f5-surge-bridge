# F5 Surge Bridge (`UWVPN.app`)

Run F5 BIG-IP SSL VPN (SAML + Duo MFA, built for **UW Husky OnNet**) as a **single userspace SOCKS5 node inside Surge Mac** — with zero kernel/utun routing conflicts, Surge Enhanced Mode kept on, and Keychain session persistence.

## Why This Exists

- **BIG-IP Edge Client** conflicts with **Surge Enhanced Mode** on macOS because Edge Client routes Surge's `198.18.0.0/15` fake-IP DNS block into the F5 `utun` tunnel.
- Even **F5 Access for macOS** installs system `utun` routes (`10.0.0.0/8`, `172.16.0.0/12`, etc.) and cannot be used as a selective Surge outbound policy.
- **UWVPN.app** replaces the system VPN tunnel with `openconnect --script-tun` and a gVisor userspace SOCKS5 stack on `127.0.0.1:11080`. It supports TCP `CONNECT` and `UDP ASSOCIATE` over the IPv4 and IPv6 addresses assigned by the VPN gateway.
  - **Surge Enhanced Mode stays ON** (Headscale / Tailscale / Surge rules all work normally).
  - **One tunnel, two modes via Surge**:
    - Normal **Rule mode**: only campus routes/domains go through `UW-Campus -> UW-VPN` (and automatically fall back to `DIRECT` when disconnected).
    - **Global Proxy -> `UW-VPN`**: temporarily route all traffic out through UW's public campus IP (using the default `huskyonnet-ns.uw.edu` gateway).
  - **Session Persistence & Keepalive**: stores `MRHSession` + `F5_ST` (~72h) in macOS Keychain, detaches cleanly via `SIGHUP` on disconnect/quit without invalidating the server session, runs periodic `/vdesk/timeoutagent-i.php` keepalives, and reconnects automatically on wake or network changes.

## Repository Layout

- `src/UWVPN/` — Native Swift macOS menu bar app (`UWVPN.app`) + `tun-bridge.sh`
- `src/tun-socks/` — Userspace IPv4/IPv6 packet stack and SOCKS5 server
- `scripts/` — Reproducible builds for portable `openconnect` and `UWVPN.app` (Apple system dylibs only)
- `surge/` — Mac-only Surge profile snippet (`#!REQUIREMENT SYSTEM='macOS'`) and `#!system=mac` module template
- `docs/` — [Architecture](docs/architecture.md) and [Code Review & Roadmap](docs/review-and-roadmap.md)
- `prototypes/` — Early CLI/Swift proof-of-concept scripts from initial F5 SAML debugging
- `.github/workflows/release.yml` — Automated macOS Universal (`arm64` + `x86_64`) build & GitHub Release workflow

## Quick Start (Prebuilt Release)

1. Download `UWVPN-macOS-universal.zip` (or `arm64`/`x86_64`) from [Releases](../../releases), unzip, and move `UWVPN.app` to `/Applications/`.
2. Add the macOS-only `UW-VPN` node and `UW-Campus` fallback group to your Mac Surge profile. If you already have a `UW-VPN` node, add `udp-relay=true` to its existing definition. See [`surge/Eagle-laptop.snippet.conf`](surge/Eagle-laptop.snippet.conf).
3. With Surge running, open `UWVPN.app` and choose **Install / Update Surge Module** from the menu bar. The app writes and enables **UW Husky OnNet** for the active profile.
4. Choose **Connect (Web Login)** and complete UW NetID + Duo. Connect to **Campus Only** to populate the UW split rules.

## Custom F5 Gateways

Open **Gateway → Edit Gateway Configuration** to create or open `~/Library/Application Support/UWVPN/config.json`. The file starts with the UW presets. Use a unique `id`, a display `name`, and a `gatewayURL` with a hostname and root HTTPS URL on port 443. Set `defaultGateway` to an ID in `gateways`. A saved menu selection takes precedence while that ID exists. Optional `directHosts` entries add direct Surge rules for login hosts such as your identity provider.

Set `splitRules` to `true` on the one gateway that should supply F5 split routes to the Surge module. For an installation using only the SOCKS5 outbound, omit `splitRules` or set it to `false` on each entry. Relaunch UWVPN after saving, then run **Install / Update Surge Module** again to apply the routing changes.

```json
{
  "defaultGateway": "work",
  "gateways": [
    {
      "id": "work",
      "name": "Work VPN",
      "gatewayURL": "https://vpn.example.com/",
      "splitRules": true
    }
  ],
  "directHosts": ["login.example.com"]
}
```

## Build From Source

Requires Xcode Command Line Tools, Go 1.27.3 or newer, and OpenSSL static libraries (`openssl@3`):

```zsh
chmod +x scripts/build-helpers.sh scripts/build-app.sh
./scripts/build-app.sh
```

Output bundle: `dist/UWVPN.app` (verified via `otool -L` to require no Homebrew/third-party dylibs at runtime).

## Current Limitations

- IPv6 destinations require an IPv6 tunnel address from F5 and a route to the destination on the VPN side. SOCKS5 hostnames use the DNS servers supplied by F5. Fragmented SOCKS5 UDP datagrams are unsupported.
- The web login implementation targets F5 gateways that issue `MRHSession` and `F5_ST` cookies. UW Husky OnNet is the default preset.
