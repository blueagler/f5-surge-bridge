# F5 Surge Bridge (`UWVPN.app`)

Run F5 BIG-IP SSL VPN (SAML + Duo MFA, built for **UW Husky OnNet**) as a **single userspace SOCKS5 node inside Surge Mac** — with zero kernel/utun routing conflicts, Surge Enhanced Mode kept on, and Keychain session persistence.

## Why This Exists

- **BIG-IP Edge Client** conflicts with **Surge Enhanced Mode** on macOS because Edge Client routes Surge's `198.18.0.0/15` fake-IP DNS block into the F5 `utun` tunnel.
- Even **F5 Access for macOS** installs system `utun` routes (`10.0.0.0/8`, `172.16.0.0/12`, etc.) and cannot be used as a selective Surge outbound policy.
- **UWVPN.app** replaces the system VPN tunnel with a local userspace stack (`openconnect --script-tun` + `ocproxy`) on `127.0.0.1:11080`:
  - **Surge Enhanced Mode stays ON** (Headscale / Tailscale / Surge rules all work normally).
  - **One tunnel, two modes via Surge**:
    - Normal **Rule mode**: only campus routes/domains go through `UW-Campus -> UW-VPN` (and automatically fall back to `DIRECT` when disconnected).
    - **Global Proxy -> `UW-VPN`**: temporarily route all traffic out through UW's public campus IP (using the default `huskyonnet-ns.uw.edu` gateway).
  - **Session Persistence & Keepalive**: stores `MRHSession` + `F5_ST` (~72h) in macOS Keychain, detaches cleanly via `SIGHUP` on disconnect/quit without invalidating the server session, runs periodic `/vdesk/timeoutagent-i.php` keepalives, and reconnects automatically on wake or network changes.

## Repository Layout

- `src/UWVPN/` — Native Swift macOS menu bar app (`UWVPN.app`) + `tun-bridge.sh`
- `scripts/` — Reproducible builds for portable `openconnect`, `ocproxy`, and `UWVPN.app` (links only Apple system dylibs)
- `surge/` — Mac-only Surge profile snippet (`#!REQUIREMENT SYSTEM='macOS'`) and `#!system=mac` module template
- `docs/` — [Architecture](docs/architecture.md) and [Code Review & Roadmap](docs/review-and-roadmap.md)
- `prototypes/` — Early CLI/Swift proof-of-concept scripts from initial F5 SAML debugging
- `.github/workflows/release.yml` — Automated macOS Universal (`arm64` + `x86_64`) build & GitHub Release workflow

## Quick Start (Prebuilt Release)

1. Download `UWVPN-macOS-universal.zip` (or `arm64`/`x86_64`) from [Releases](../../releases), unzip, and move `UWVPN.app` to `/Applications/`.
2. Install the Surge module (generates `uw-vpn.sgmodule` using your `$HOME` path):
   ```zsh
   ./surge/install-surge-module.sh
   ```
3. Add the macOS-only `UW-VPN` node and `UW-Campus` fallback group to your Mac Surge profile (see [`surge/Eagle-laptop.snippet.conf`](surge/Eagle-laptop.snippet.conf)), then enable the **UW Husky OnNet** module in Surge.
4. Launch `UWVPN.app`, click the menu bar shield icon -> **Connect (UW Web Login)...**, and complete UW NetID + Duo once.

## Build From Source

Requires Xcode Command Line Tools and OpenSSL static libraries (`openssl@3`):

```zsh
chmod +x scripts/build-helpers.sh scripts/build-app.sh
./scripts/build-app.sh
```

Output bundle: `dist/UWVPN.app` (verified via `otool -L` to require no Homebrew/third-party dylibs at runtime).

## Current Limitations

- `ocproxy` supports **IPv4 TCP** over SOCKS5 (`CONNECT`); UDP relay and IPv6 literals are not yet supported (see [Roadmap](docs/review-and-roadmap.md)).
- Default gateways target UW Husky OnNet (`huskyonnet-ns.uw.edu` and `huskyonnet.uw.edu`).
