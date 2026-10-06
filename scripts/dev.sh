#!/usr/bin/env bash
set -euo pipefail
arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$arcade_root"
source scripts/dev-env.sh
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-3}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-3}"
command -v cargo >/dev/null || { echo 'Install Rust stable first.' >&2; exit 1; }
case "${1:-help}" in
  format)
    cargo fmt --all
    shift
    (cd apps/flutter_app && dart format "$@")
    ;;
  rust-test)
    cargo test --workspace --locked
    ;;
  rust-check)
    cargo fmt --all --check
    cargo clippy --workspace --all-targets --locked -- -D warnings
    rustfmt --edition 2021 --check core/rust/src/core_helpers.rs
    ;;
  flutter-test)
    (cd apps/flutter_app && flutter test)
    ;;
  flutter-check)
    (cd apps/flutter_app && flutter analyze)
    ;;
  build-windows)
    (cd apps/flutter_app && flutter pub get --enforce-lockfile && flutter build windows --release)
    ;;
  build-macos)
    (cd apps/flutter_app && flutter pub get --enforce-lockfile && flutter build macos --release)
    bash scripts/build-macos-core.sh
    ;;
  test)
    cargo test --workspace --locked
    (cd apps/flutter_app && flutter test)
    ;;
  check)
    cargo fmt --all --check
    cargo clippy --workspace --all-targets --locked -- -D warnings
    rustfmt --edition 2021 --check core/rust/src/core_helpers.rs
    (cd apps/flutter_app && flutter analyze)
    ;;
  relay)
    exec cargo run --locked -p arcade_relay
    ;;
  driver)
    exec cargo run --locked -p arcade_test_driver
    ;;
  smoke)
    cargo build --locked -p arcade_test_driver
    exec python3 tests/process_smoke.py
    ;;
  generate)
    command -v flutter >/dev/null || { echo 'Flutter is required; see docs/development.md.' >&2; exit 1; }
    command -v flutter_rust_bridge_codegen >/dev/null || {
      echo 'Install matching codegen: cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked' >&2
      exit 1
    }
    (cd apps/flutter_app && flutter pub get)
    flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml
    ;;
  build-linux)
    exec bash scripts/build-linux.sh
    ;;
  build-ios)
    exec bash scripts/build-ios-unsigned.sh
    ;;
  native-test)
    exec bash scripts/test-native-linux.sh
    ;;
  desktop)
    command -v flutter >/dev/null || { echo 'Flutter is required; see docs/development.md.' >&2; exit 1; }
    [[ -f apps/flutter_app/lib/src/rust/frb_generated.dart ]] || {
      echo 'Bridge bindings are missing. Run bash scripts/dev.sh generate in a trusted Flutter environment.' >&2
      exit 1
    }
    [[ -d apps/flutter_app/linux ]] || {
      echo 'Flutter platform runners are missing. See docs/development.md before building.' >&2
      exit 1
    }
    if ! pkg-config --exists keybinder-3.0 && [[ -f .tools/native/usr/lib/pkgconfig/keybinder-3.0.pc ]]; then
      export PKG_CONFIG_PATH="$arcade_root/.tools/native/usr/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
      export LD_LIBRARY_PATH="$arcade_root/.tools/native/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    cd apps/flutter_app
    exec flutter run -d linux
    ;;
  *)
    echo 'Usage: bash scripts/dev.sh {format|test|check|rust-test|rust-check|flutter-test|flutter-check|relay|driver|smoke|generate|desktop|build-linux|build-windows|build-macos|build-ios|native-test}'
    ;;
esac
