# Development

Run all commands from the repository root.

## Toolchain

| Tool | Version |
| --- | --- |
| Flutter | 3.47.2 (Dart 3.13) |
| Rust | 1.98.1 |
| flutter_rust_bridge | 2.13.0, for both the Dart runtime and the code generator |

CI uses the same versions. `scripts/dev-env.sh`, which every script sources, prefers installed tools and falls back to toolchains under `.tools/` for the current process only. It never edits shell or system configuration.

## Linux prerequisites

Debian and Ubuntu:

```bash
sudo apt-get install clang cmake ninja-build pkg-config \
  libgtk-3-dev libkeybinder-3.0-dev libdbus-1-dev libsecret-1-dev
```

Arch: `clang cmake ninja pkgconf gtk3 libkeybinder3 libsecret`.

For running the app you also need a Secret Service provider and, on Wayland, `wl-clipboard`. See [Linux](linux.md#requirements).

## Commands

`scripts/dev.sh` wraps the common tasks:

| Command | What it does |
| --- | --- |
| `bash scripts/dev.sh desktop` | Run the Linux app in debug mode |
| `bash scripts/dev.sh build-linux` | Build the release bundle and `dist/Arcade-Clipboard-linux-x64.tar.gz` |
| `bash scripts/install-linux.sh` | Install the release bundle for the current user |
| `bash scripts/dev.sh test` | Rust workspace tests and Flutter tests |
| `bash scripts/dev.sh check` | `rustfmt`, Clippy with warnings as errors, and `flutter analyze` |
| `bash scripts/dev.sh smoke` | Pair two real core processes and sync between them |
| `bash scripts/dev.sh native-test` | Pairing, sync and picker paste on a live Hyprland session |
| `bash scripts/dev.sh relay` | Run the relay on `127.0.0.1:8787` |
| `bash scripts/dev.sh generate` | Regenerate the Flutter–Rust bindings |
| `bash scripts/dev.sh build-windows` | Build the Windows desktop bundle (Windows runner) |
| `bash scripts/dev.sh build-macos` | Build the macOS desktop bundle (macOS runner) |
| `bash scripts/dev.sh build-ios` | Build the unsigned IPA (macOS only) |

## Project structure

[Architecture](architecture.md) describes the layout and how the pieces fit together. A few things to know before changing code:

- **Bindings.** `apps/flutter_app/lib/src/rust/` and `core/rust/src/frb_generated.rs` are generated. The Rust API is a single JSON function, so adding an operation needs no regeneration: add a branch to the operation match in `core.rs` and call it from Dart with `CoreApi.invoke`.
- **Platform runners.** `apps/flutter_app/{linux,ios,android,macos,windows}` are customized. Do not run `flutter create` over them. `scripts/prepare-runners.sh` only creates runners that are missing.
- **iOS project.** `scripts/setup-ios.rb` adds the extension targets and build settings to the Xcode project. Run it after changing the extension wiring. It edits `project.pbxproj` in place and is safe to rerun. On Linux, run it with any Ruby that has the `xcodeproj` gem.
- **Desktop plugin.** Native Linux code is in `platform/desktop/arcade_desktop_bridge/linux`. The Wayland capture helper (`wl_capture_helper.cc`) is built as a separate executable and installed into the bundle's `lib/` directory.

## Running two instances

Use [Arcade Link's isolated runner](https://github.com/qa-p1/Arcade-Link/blob/main/tools/e2e.py)
for automated desktop checks: private D-Bus, Xvfb, temporary HOME/XDG and
`ARCADE_HOME`, with the live Wayland session excluded. Use a distinct
`ARCADE_DATA_DIR` for each profile inside that session. The override separates
profile data and disables the single-instance check; it does not by itself
isolate desktop shortcuts, clipboard access or the system keyring.

For a deliberate manual pairing test, use two disposable profiles and choose
different shortcuts. `native-test` is explicitly a live Hyprland test; run it
only when testing the real session is intended. Keep every test environment
override scoped to the command. Never add temporary paths to shell profiles,
compositor configuration or persistent environment files.

## Debugging

- `ARCADE_DEBUG=1` prints capture, picker, paste and connection events to stderr. The last 200 events are also kept in memory by `Diagnostics` (`lib/services/diagnostics.dart`). Never log clipboard contents.
- `ARCADE_CORE_LIBRARY=/path/to/libarcade_core.so` loads a specific build of the core.
- `ARCADE_RELAY_URL` sets the default relay for new profiles.
- On Hyprland, `hyprctl binds` and `hyprctl clients` show the app's binding and windows.

## Tests

### Automated

| Suite | Covers |
| --- | --- |
| `cargo test -p arcade_core` | Noise sessions and tampering, pairing consent and replay, signatures, revocation, storage encryption and migrations, size limits, offline catch-up, pins, deduplication, reconnection after restart, LAN-to-relay failover |
| `cargo test -p arcade_relay` | Route limits and real WebSocket forwarding |
| `flutter test` (in `apps/flutter_app`) | Onboarding, history, search, settings, picker keyboard navigation and layouts |
| `bash scripts/dev.sh smoke` | Two separate processes through the real API and system keyring |
| `dbus-run-session -- bash tests/with-secret-service.sh` | The same, against an isolated Secret Service |
| `bash scripts/dev.sh native-test` | Real pairing, sync and Enter-to-paste into a GTK test window on Hyprland |

The Rust integration tests start real listeners on loopback. Several of them depend on timing; if one fails under heavy load, run it again on its own before investigating.

### Manual checks before a release

With two devices paired:

- [ ] Copy text with Unicode and surrounding whitespace on one device. It appears exactly once on the other, and the other device's clipboard is unchanged.
- [ ] Copy the same text again. No duplicate appears; an older copy moves to the top on both devices.
- [ ] Open the picker, move the selection, press Enter. The clip is pasted into the previous window. Repeat in a terminal.
- [ ] Press Escape in the picker. Focus returns to the previous window and nothing is pasted.
- [ ] Copy HTML, an image and a group of files. Each can be opened, copied and saved on the other device.
- [ ] Quit one device, add clips on the other, start it again. The clips arrive once.
- [ ] Pin and unpin while disconnected. Both devices agree after reconnecting.
- [ ] Remove a device. It disconnects and its new clips are not accepted.
- [ ] Turn on Private mode. Copies are not added.
- [ ] With a relay configured, disconnect the LAN. Clips still arrive; when the LAN returns, the direct connection is used again.

On iPhone, additionally:

- [ ] Join a mesh. Local Network and camera prompts appear, and pairing succeeds.
- [ ] Share text, a photo and a file. Open the app; each is added once.
- [ ] Enable the keyboard, insert a clip in Notes, search with its keys, switch back with the globe key.
- [ ] Leave the app for a few minutes, add clips elsewhere, return. They arrive within seconds.

## Continuous integration

| Workflow | Trigger | Does |
| --- | --- | --- |
| **Core and desktop builds** (`ci.yml`) | Push to `main`, pull requests, manual | Rust formatting, Clippy and tests; Flutter analysis and tests; Linux release build, uploaded as `Arcade-Clipboard-linux-x64`; Windows and macOS desktop builds, each running the Rust core tests |
| **Release** (`release.yml`) | Push to `main` (nightly), `v<version>` tags (stable), manual | Linux tarball, Windows Inno installer, macOS dmg, `arcade-release.json` and `SHA256SUMS.txt`. See [Releases](releases.md). |
| **Build iPhone IPA** (`build-ios-ipa.yml`) | Manual | Builds the Rust core for iOS, builds the app and extensions without signing, validates and uploads the IPA. See [iPhone](ios.md). |

Third-party actions are pinned to commit SHAs.

## Other platforms

- **Android:** install the SDK and NDK and the Rust Android targets, run `python3 scripts/build-android-core.py`, then `flutter build apk` in `apps/flutter_app`.
- **macOS:** `flutter build macos --release`, then `bash scripts/build-macos-core.sh`.
- **Windows:** `flutter build windows`. The CMake build compiles and bundles the Rust DLL.

[Relay deployment](relay-deployment.md) covers hosting the relay.
