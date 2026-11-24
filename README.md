# UWVPN

UWVPN is a macOS menu bar app for F5 BIG-IP VPNs that use web sign-in. It exposes a SOCKS5 proxy at `127.0.0.1:11080` for Surge. OpenConnect and a gVisor userspace stack carry TCP and UDP over the VPN without creating a system tunnel interface or changing macOS routes.

## Install and connect

1. On macOS 26 or later, download `UWVPN-macOS-universal.zip`, unzip it, and move `UWVPN.app` to `/Applications`. [GitHub Releases](../../releases)
2. Add the definitions in [surge/uw-vpn.conf](surge/uw-vpn.conf) to your Mac Surge profile. Set `udp-relay=true` on `UW-VPN` to use UDP through Surge.
3. With Surge running, open UWVPN and choose **Install / Update Surge Module**. The app writes and enables rules for the configured gateway and login hosts.
4. Choose **Connect (Web Login)** and complete UW NetID and Duo. Use **Campus Only** once to populate the campus split rules. In Surge Rule mode, the `UW-Campus` group prefers `UW-VPN` and uses `DIRECT` when the proxy is unavailable. To send all traffic through UW, select **All Internet** in UWVPN and use `UW-VPN` as the Surge Global Proxy policy.

Use **Test VPN Connectivity** to check the active session. Proxy hostnames resolve through F5-provided DNS. IPv6 destinations require an IPv6 address and route from the VPN gateway.

## Configure gateways

Choose **Gateway → Edit Gateway Configuration** to open `~/Library/Application Support/UWVPN/config.json`. UW presets are included by default. For a custom F5 gateway, use a unique `id`, a display `name`, and a root HTTPS URL on port 443. Choose a `defaultGateway` ID. An existing menu selection takes precedence while its ID remains in the configuration.

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

At most one gateway can publish split rules. `directHosts` optionally adds Surge exemptions for sign-in domains. Relaunch UWVPN and run **Install / Update Surge Module** after changing the configuration. Supported F5 sign-in flows issue both `MRHSession` and `F5_ST` cookies.

## Build and test

Use macOS 26 or later, Xcode Command Line Tools, and Go 1.27.3 or newer. The script builds pinned OpenConnect and OpenSSL sources and writes the signed app to `dist/UWVPN.app`. It also reuses a previously built OpenConnect binary in `build/helpers-<arch>/bin/`.

```sh
./scripts/build-app.sh
(cd src/tun-socks && CGO_ENABLED=0 go test -mod=readonly ./...)
codesign --verify --deep --strict dist/UWVPN.app
```

See [AGENTS.md](AGENTS.md) for source entry points and verification commands. Each successful GitHub Actions build produces Apple Silicon, Intel and Universal ZIPs. A version tag publishes all three to GitHub Releases.
