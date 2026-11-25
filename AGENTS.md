# UWVPN repository guide

## Source entry points

- `src/UWVPN/AppDelegate.swift` owns the macOS menu, configuration and system events. `Models.swift` validates gateway configuration. `WebLoginWindow.swift` and `KeychainStore.swift` manage sign-in and sessions.
- `src/UWVPN/GatewayRelay.swift` binds gateway connections to the physical interface. Keep the CONNECT host allowlist and reject Surge fake addresses in both IP families.
- `src/UWVPN/TunnelController.swift` owns OpenConnect and starts `tun-bridge.sh`. The script hands OpenConnect’s inherited `VPNFD` to `src/tun-socks/`. The helper publishes Surge split rules using the addresses and MTU it actually supports.
- `src/tun-socks/` implements loopback SOCKS5 TCP/UDP and VPN DNS through gVisor. Preserve raw packet boundaries and keep destination traffic inside the userspace tunnel.
- `src/UWVPN/SurgeModule.swift` generates and enables the macOS Surge module. `surge/uw-vpn.conf` contains the user’s Surge profile definitions.
- `scripts/build-app.sh` packages one architecture. `scripts/build-helpers.sh` builds pinned native dependencies. `scripts/build-universal.sh` assembles two signed architecture archives. `.github/workflows/release.yml` owns CI and publishing.

## Invariants

- The app targets macOS 26 or later on `arm64` and `x86_64`. Read the deployment target from `src/UWVPN/Info.plist`.
- The proxies bind to loopback. Keep system route changes out of the app and preserve the distinction between disconnect with session retention and server logout.
- Use the configured gateway ID and host as the session identity. Keep cookies out of arguments, logs and repository fixtures.
- The app bundle depends only on Apple system dylibs. The build must keep host package discovery isolated and verify the final signature and architectures.

## Verify changes

```sh
(cd src/tun-socks && CGO_ENABLED=0 go test -mod=readonly ./...)
/bin/zsh tests/tunnel-recovery.sh
/bin/zsh tests/gateway-relay.sh
/bin/zsh -n src/UWVPN/tun-bridge.sh
./scripts/build-app.sh
codesign --verify --deep --strict dist/UWVPN.app
```

Use `actionlint` for workflow changes. GitHub Actions builds both architectures and verifies Universal assembly. Live F5 and Surge checks require an authenticated session and test traffic through the local SOCKS5 proxy.
