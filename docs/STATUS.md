# Arcade Clipboard: status

Verified 2026-10-08 on branch `arcade/link` (version 0.1.0, Arcade Link
`v0.1.0`). This page records what is implemented and how it was checked;
the other documents describe how it works.

## Implemented

- An end-to-end encrypted clipboard history shared by your devices: QR
  pairing with a six-digit check, a mesh with no account, LAN discovery and an
  optional relay, encrypted storage, pins, deduplication, Private mode.
- Desktop (Flutter with a Rust core): automatic capture, the picker with
  automatic paste (Hyprland, X11), tray menu, launch at login. iPhone/iPad: share
  extension and clipboard keyboard. Android: share target and keyboard.
- Arcade Link (desktop only): `clipboard.add` (Send to my devices),
  `clipboard.devices` and `clipboard.pick`; clip menus offering Quick Look,
  Extract text, Analyze with Lens, Pin, Format JSON, Clean text, Convert to PNG
  and an opt-in Compress; the Connected apps page.

## Verification

| Check | Result |
|---|---|
| `cargo test --workspace` (Rust core and relay) | 63 passed |
| `flutter test` | 25 passed |
| CI: Rust, Linux bundle, Windows and macOS desktop builds with Rust core tests | passing at `0f86bc1` |
| Arcade Link e2e, `clipboard` and `clipboard_ui` groups and cross-app flows | all passing (74/74 ecosystem checks) |
| Benchmark against the 2026-10-05 baseline | startup 187.8 → 193.3 ms (+2.9 %), idle RSS 264 → 265 MiB, idle CPU 0 |

Linux on Hyprland is the main development platform and was tested end to end
on real hardware.

## Limits

- Windows and macOS build and pass the core tests in CI but have not been run
  interactively; their installers are not yet verified.
- iPhone sync runs only while the app is open; the IPA is unsigned. Android
  builds but has not been run on a device.
- Other Wayland compositors: capture needs data-control (not GNOME) and there
  is no automatic paste.
- Text clips up to 32 KiB, other clips up to 16 MiB; no folders; interrupted
  transfers restart. The relay forwards but stores nothing.
- Sending to one specific device and remote invocation are not implemented.
- Desktop memory: Flutter keeps about 265 MiB resident; a split into a
  background core and an on-demand window is a possible later change.

## Documents

| Document | Contents |
|---|---|
| [README](../README.md) | Behavior, platform table, install, pairing |
| [linux](linux.md), [ios](ios.md), [platforms](platforms.md) | Per-platform setup and limits |
| [architecture](architecture.md), [protocol](protocol.md), [security](security.md) | Design, wire protocol, threat model |
| [arcade-link](arcade-link.md) | Link actions, connected clip actions, verification |
| [development](development.md) | Building, tests, CI |
| [releases](releases.md), [relay-deployment](relay-deployment.md) | Packages and the relay |
| [Original-spec](../Original-spec.md) | The original product brief (not an implementation record) |
