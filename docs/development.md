# Development

Run commands from the repository root. The verified local toolchain is Flutter 3.47.2 / Dart 3.13.2 and Rust 1.98.1. CI uses the official Rust 1.98.0 release. Flutter Rust Bridge runtime and generated bindings are both 2.13.0.

## Linux prerequisites

Install Flutter stable, Rust, Python 3, clang, CMake, Ninja, pkg-config, GTK 3 development files, keybinder 3 development files and a working Secret Service implementation.

Ubuntu/Debian native dependencies:

~~~bash
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libkeybinder-3.0-dev libdbus-1-dev libsecret-1-dev libstdc++-12-dev
~~~

On Arch-based systems use the corresponding clang, cmake, ninja, gtk3, keybinder3 and libsecret packages. Hyprland capture/paste uses wl-clipboard and hyprctl, with Lua and legacy configuration support. X11 focus/paste uses the bundled X11 helper. Generic Wayland has no global shortcut provider implemented here; bind a system shortcut to `clipboard --overlay` (the running instance opens the picker) and use copy fallback. Wayland capture needs wl-clipboard 2.2+. Set `ARCADE_DEBUG=1` for diagnostics on stderr. Setting `ARCADE_DATA_DIR` allows a second, independent local instance for pairing tests.

## Commands

| Command | Result |
| --- | --- |
| bash scripts/dev.sh desktop | Run Linux debug client |
| bash scripts/dev.sh build-linux | Build release bundle and tar.gz |
| bash scripts/install-linux.sh | Install built bundle under the user data directory |
| bash scripts/dev.sh test | Rust workspace and Flutter tests |
| bash scripts/dev.sh check | Rust format/Clippy and Flutter analysis |
| bash scripts/dev.sh smoke | Two actual Rust API processes using system secure storage |
| dbus-run-session -- bash tests/with-secret-service.sh | Isolated synthetic Secret Service/process acceptance |
| bash scripts/dev.sh native-test | Hyprland native pairing/history/Enter-paste acceptance |
| bash scripts/dev.sh relay | Local relay on 127.0.0.1:8787 |
| bash scripts/dev.sh generate | Regenerate matching Flutter/Rust bindings |
| bash scripts/dev.sh build-ios | On macOS, build and package unsigned iPhone IPA |

Generated bindings and customized platform runners are included. Do not regenerate runners over them. scripts/prepare-runners.sh only fills missing runners.

scripts/dev-env.sh prefers installed tools and scopes optional local toolchains to the current process. No temporary toolchain paths belong in shell, compositor or systemd startup configuration.

## Isolated clients

Set ARCADE_DATA_DIR to a different durable directory for each process. Each profile has its own secure identity and encrypted database. Do not open the same profile simultaneously. One process per profile is enforced.

For two local GUI clients, use distinct profiles and change the second client's shortcut if it conflicts. Pair through Devices. For reproducible automated pairing, run the process smoke test; it does not replace the normal secure store with a test key file.

ARCADE_CORE_LIBRARY is an optional runtime override for development. Release bundles locate their Rust library automatically. ARCADE_RELAY_URL supplies an optional deployment default; Settings can override it.

## Other builds

Android: install an Android SDK/NDK and the Rust Android targets, run python3 scripts/build-android-core.py, then flutter build apk in apps/flutter_app. The Kotlin share target, provider and IME are included in the runner.

iOS: use the unsigned IPA workflow or follow docs/ios-install.md. Xcode/macOS are required for native compilation. scripts/setup-ios.rb wires both extensions and the Rust archive.

macOS: flutter build macos --release followed by bash scripts/build-macos-core.sh on a Mac. Windows: flutter build windows on Windows; its CMake build compiles and bundles the Rust DLL.

[Relay hosting](relay-deployment.md) describes the domain/server setup separately from app development.
