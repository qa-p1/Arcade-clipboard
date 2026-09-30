# Arcade Clipboard

Arcade Clipboard is a device-to-device clipboard history. A clip explicitly added on one trusted device is synchronized into the mesh history on the others. Receiving a clip never silently replaces the receiving device's normal OS clipboard; choosing a clip is the action that copies or pastes it.

**Status: development checkpoint, not an installable or release-ready app.** This checkout contains the Flutter UI source, Rust core, platform adapter source, mobile extension source, relay service, and development scripts. Flutter bridge bindings and generated platform runners are not checked in, and native pairing, capture, focus restoration, and paste have not been accepted on real devices. Do not use it with sensitive clipboard contents yet. See [platform limits](docs/platform-limitations.md), [verification status](docs/verification/toolchain-blocker.md), and the [security review](docs/security-review.md).

## What's in the repository

- `apps/flutter_app`: shared Flutter application source and Dart state tests.
- `core/rust`: mesh identity, pairing, authenticated encrypted transport, encrypted local payload storage, history, and synchronization source.
- `platform/desktop`: small Windows, macOS, Linux, and Hyprland integration source.
- `platform/ios` and `platform/android`: native share/keyboard and protected handoff source.
- `services/relay`: a standalone opaque WebSocket relay. The current client does not use it as a remote fallback.
- `tests`: Rust integration and process-smoke test sources; their presence is not a claim that this checkout passed them.

## Development entry points

From the repository root, `bash scripts/dev.sh relay` starts the local relay. `bash scripts/dev.sh test` and `bash scripts/dev.sh smoke` are available for a developer who chooses to run the Rust checks; no tests or native/emulator checks were run for this publishing checkpoint. `bash scripts/dev.sh desktop` currently stops with an explanatory preflight until Flutter/Rust bridge bindings and a Linux runner have been generated in a compatible Flutter environment.

See [development](docs/development.md) for prerequisites and the path to a two-device test. That acceptance flow is not currently ready to execute from a clean checkout. No public relay is provisioned.

## Project docs

- [Architecture and module boundaries](docs/architecture.md)
- [Development setup and commands](docs/development.md)
- [Protocol v1](docs/protocol.md)
- [Security review and open risks](docs/security-review.md)
- [Platform limits and readiness](docs/platform-limitations.md)
- [Desktop integration](docs/desktop-integration.md)
- [Mobile integration](docs/mobile-integration.md)
- [Manual acceptance checklist](docs/acceptance.md)
- [Relay behavior](services/relay/README.md)

A platform should be called supported only after its build, permissions, clipboard behavior, lifecycle, focus, and paste or insertion path have been exercised on that platform. This checkpoint makes no such release claim.
