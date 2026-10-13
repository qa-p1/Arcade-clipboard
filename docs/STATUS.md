# Arcade Clipboard: status

Verified 2026-10-08 on branch `arcade/link` (version 0.1.0, Arcade Link
`v0.1.0`). On 2026-10-10 the Link pin moved to `v0.2.0`, which adds Arcade
Shelf and Arcade Find to the shared app metadata (no protocol changes). This
page records what is implemented and how it was checked; the other documents
describe how it works.

Add to Shelf (Arcade Shelf's `shelf.add`) is offered for text, link, rich
text, image and file clips. It is covered by Rust unit tests against a mock
Shelf manifest; the Flutter app was not rebuilt for it (the menus render
offers generically from the core's JSON) and no run against a real Shelf is
recorded yet.

## Implemented

- An end-to-end encrypted clipboard history shared by your devices: QR
  pairing with a six-digit check, a mesh with no account, LAN discovery and an
  optional relay, encrypted storage, pins, deduplication, Private mode.
- Desktop (Flutter with a Rust core): automatic capture, the picker with
  automatic paste (Hyprland, X11), tray menu, launch at login. iPhone/iPad: share
  extension and clipboard keyboard. Android: share target and keyboard.
- Arcade Link (desktop only): `clipboard.add` (Send to my devices),
  `clipboard.devices` and `clipboard.pick`; clip menus offering Quick Look,
  Extract text, Analyze with Lens, Pin, Format JSON, Clean text, Convert to PNG,
  Add to Shelf and an opt-in Compress; the Connected apps page, which also lists Arcade
  Shelf and Arcade Find (glyphs and accents from Link `v0.2.0`) with a Get
  link when they are not installed.

## Arcade Tools hub (2026-10-12, Link `v0.3.0`)

- Hub methods: settings, restart, the Private mode tray item, picker
  shortcut rebinding (Hyprland answers with a bind line), and allowlisted
  settings export/import with a backup. Manifest additions: menu, logs, docs,
  install method.
- Tray hand-off: the Flutter tray hides while Tools hosts the tray and
  returns when Tools stops (Linux, Windows and macOS bridges).
- Install standard: the AppImage launcher (`arcade-clipboard-launcher`) adds
  `--install`, `--uninstall`, `--repair`, `--integration-status` and the
  first-run install dialog; macOS offers Move to Applications; Windows uses
  the shared per-user Inno installer (`arcade.iss` and its PowerShell helper
  from Link `v0.3.0`). Windows/macOS answer `--integration-status`; macOS
  `--install --silent --no-launch` copies the bundle and installs its CLI.
- Checked locally: `cargo fmt`, `cargo clippy -D warnings`, `cargo test
  --workspace` in Link's isolated runner, `flutter analyze` and `flutter
  test` (27 passed). The Linux bundle needs keybinder headers, so it is built
  in CI.

## Verification

| Check | Result |
|---|---|
| `cargo test --workspace` (Rust core and relay) | 63 passed |
| `flutter test` | 25 passed |
| CI: Rust, Linux bundle, Windows and macOS desktop builds with Rust core tests | passing at `0f86bc1` |
| Branch CI: Windows Inno installer and macOS dmg lifecycle checks | Defined on `arcade/tools-hub`; first run pending. CI only, not a real desktop. |
| Installer changes, local Linux validation (2026-10-13) | 73 Rust tests and 27 Flutter tests passed; Rust formatting/Clippy, Flutter analysis, docs/checksums, YAML, Bash/ShellCheck and PowerShell parsing passed. No Windows/macOS installer was run locally. |
| Linux AppImage, local build | Built `Arcade-Clipboard-0.1.0-x86_64.AppImage`; `--version` and `--arcade-manifest` passed in Arcade Link's isolated e2e runner; `ldd` checked 11 ELF files with no missing libraries; size 14,760,440 bytes | 2026-10-11 |
| Arcade Link e2e, `clipboard` and `clipboard_ui` groups and cross-app flows | all passing (74/74 ecosystem checks) |
| Benchmark against the 2026-10-05 baseline | startup 187.8 → 193.3 ms (+2.9 %), idle RSS 264 → 265 MiB, idle CPU 0 |

Linux on Hyprland is the main development platform and was tested end to end
on real hardware.

The new Windows CI check uses the runner account and an isolated `ARCADE_HOME`.
It checks `/SILENT` and `/VERYSILENT` parity, selected/deselected startup tasks,
receipt/CLI/launcher/Apps & features metadata, isolated PATH, `--version`,
`--integration-status` and `--quit` with no resident. A successor install must
survive the old helper's ownership refusal (exit 10) and the old Inno
uninstaller; final uninstall must remove the shared files and PATH entry.
The manifest cleanup uses a fixture saved from the installed app's
`--arcade-manifest`, without starting a resident desktop session.

The macOS check mounts the packaged dmg read-only, runs
`--install --silent --no-launch` with temporary HOME/XDG/`ARCADE_HOME`, compares
the copied executable and Rust library, and checks the `macos-bundle` receipt,
CLI symlink, version and integration status. It also asserts that no shell
profile was written. Both jobs upload the actual installer assets and use the
release workflow's existing `scripts/package-desktop.py`. These checks are
**CI only, not a real desktop**; no passing run is recorded here yet.

## Limits

- Windows and macOS build and pass the core tests in recorded CI, but have not
  been run interactively. Installer coverage is now defined in branch CI;
  its first result is pending. macOS installer uninstall/repair, Gatekeeper
  and a real desktop session remain unverified by these checks.
- The AppImage has only had isolated command-line smoke checks, not a real
  desktop install test. Its `--install` and `--uninstall` behavior is not
  implemented yet; the release manifest arguments prepare for a separate port.
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
