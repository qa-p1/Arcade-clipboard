# Development

## Current checkout status

This is a source checkpoint, not a runnable release bundle. The Flutter app directory contains product Dart source but no generated `linux/`, `windows/`, `macos/`, `ios/`, or `android/` runner. Flutter Rust Bridge generated bindings are also absent. The normal build path therefore cannot launch the client until a trusted development machine generates the bindings and platform runner. The automatic-review block that prevented Flutter CLI execution here is recorded in [toolchain-blocker.md](verification/toolchain-blocker.md).

No tests, native builds, or emulator checks were run for this publishing checkpoint. The commands below describe available developer actions; they are not results. Use synthetic clipboard text only until the [security and platform gates](security-review.md) are closed.

## Toolchain

The repository targets Rust stable 1.98.1, Flutter 3.47.5 / Dart 3.13.4, and `flutter_rust_bridge_codegen` 2.13.0. Keep the Dart and Rust bridge package versions aligned with the generator. Linux desktop development additionally needs a C/C++ compiler, CMake, Ninja, pkg-config, GTK 3 development files, libclang, and a running Secret Service. X11 paste requires `xdotool`. Hyprland-specific dependencies and limitations are listed in [desktop integration](desktop-integration.md).

`bash scripts/bootstrap-toolchains.sh` can install optional SDKs under `.tools`; it does not modify shell startup files. On a native workstation, standard system Rust and Flutter installations are also suitable. Commands are invoked through Bash and can be run from Fish without sourcing Bash configuration.

## Rust core and relay

From the repository root:

```sh
bash scripts/dev.sh test       # Rust workspace tests
bash scripts/dev.sh check      # formatting and Clippy
bash scripts/dev.sh relay      # local relay on 127.0.0.1:8787
bash scripts/dev.sh smoke      # two-process core smoke test
```

The Rust core uses the operating system's secure credential store and has no plaintext key fallback. Linux needs an unlocked Secret Service session. Android's Rust identity store is deliberately unconfigured and fails closed, so Android mesh startup is blocked. The local relay is not a deployed public service and is not currently used by the clients.

## Generate and run a Linux client

On a machine where Flutter can run normally:

```sh
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
bash scripts/prepare-runners.sh
bash scripts/dev.sh generate
bash scripts/dev.sh desktop
```

`prepare-runners.sh` creates missing standard Flutter runners and preserves the existing product source and curated `pubspec.yaml`. The generator creates Rust/Dart bridge files; review and commit those generated files if the team decides to keep them in source control. The `desktop` command also builds the Rust core and then launches Flutter for Linux.

For separate development profiles, use two terminals:

```sh
env ARCADE_DATA_DIR=/tmp/arcade-dev-a bash scripts/dev.sh desktop
env ARCADE_DATA_DIR=/tmp/arcade-dev-b bash scripts/dev.sh desktop
```

The checkout is not yet ready for the requested two-desktop acceptance flow: the bridge and runner must first be generated, and the platform issues in [platform limitations](platform-limitations.md) must be resolved and exercised. Use [acceptance](acceptance.md) as a manual checklist only after those prerequisites are met.

## iPhone and Android

The native source lives under `platform/ios` and `platform/android`. It still needs generated runners, correct target/channel registration, signing, and device validation. The iOS project installer currently needs compatibility work against the chosen `xcodeproj` API before it can be relied on. Android's Rust secure identity integration is a hard blocker. Follow [mobile integration](mobile-integration.md) for the actual gates; these instructions are not a claim that either mobile build works.

## CI

`.github/workflows/ci.yml` defines Rust, Flutter, and Linux build jobs. A workflow definition is not evidence of a successful run. For this checkpoint no tests were run locally, and its commit message uses GitHub's CI-skip directive to honor the user's instruction not to run tests.
