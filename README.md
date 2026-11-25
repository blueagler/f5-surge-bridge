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

The gateway relay resolves the VPN host using the physical interface's DNS servers. A gateway can list additional resolver IP addresses in `fallbackDNSServers`. The UW presets default to public fallback servers. Custom gateways default to an empty list. An explicit empty list disables those extra lookups. The relay also consults the macOS resolver if the direct lookups return no usable address. Traffic inside the VPN uses the DNS servers assigned by F5.

## Build and test

Use macOS 26 or later, Xcode, and Go 1.27.3 or newer. The script builds pinned OpenConnect and OpenSSL sources and writes the app to `dist/UWVPN.app`. It reuses a previously built OpenConnect binary in `build/helpers-<arch>/bin/` when the toolchain fingerprint matches.

Personal builds use ad-hoc signing. `Info.plist` records the full Git revision, whether the checkout had local changes, and the distribution mode. Use these builds locally. GitHub Releases publishes Developer ID builds.

```sh
./scripts/build-app.sh
python3 tests/build-release.py
(cd src/tun-socks && CGO_ENABLED=0 go test -mod=readonly ./...)
codesign --verify --deep --strict dist/UWVPN.app
python3 tests/packaged-tunnel.py dist/UWVPN.app
```

See [AGENTS.md](AGENTS.md) for source entry points and verification commands. Pull-request CI builds Apple Silicon, Intel, and Universal archives without signing credentials. A `vMAJOR.MINOR.PATCH` tag requires a clean checkout and produces Developer ID signed, hardened-runtime archives. The release job submits all three archives for notarization, staples each app, runs Gatekeeper checks and `tests/packaged-tunnel.py`, then publishes the verified ZIPs.

Configure the `UWVPN_SIGN_IDENTITY` repository variable with the full Developer ID Application certificate name. Configure these repository secrets:

- `UWVPN_DEVELOPER_ID_P12`: the base64-encoded Developer ID certificate and private key.
- `UWVPN_DEVELOPER_ID_P12_PASSWORD`: the certificate import password.
- `UWVPN_CI_KEYCHAIN_PASSWORD`: a strong, random password for temporary CI keychains.
- `UWVPN_APPLE_ID`, `UWVPN_APPLE_PASSWORD`, and `UWVPN_TEAM_ID`: the Apple account and app-specific password used for notarization.

The workflow stores notary credentials only in a temporary runner keychain. Keep certificates, keychain profiles, and notary credentials out of the repository and build logs. A missing signing identity, mismatched tag, ad-hoc public build, or failed notarization stops publication.
