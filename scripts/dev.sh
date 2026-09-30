#!/usr/bin/env bash
set -euo pipefail
arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$arcade_root"
if [[ -x "$arcade_root/.tools/cargo/bin/cargo" ]]; then
  export CARGO_HOME="$arcade_root/.tools/cargo"
  export RUSTUP_HOME="$arcade_root/.tools/rustup"
  export PATH="$CARGO_HOME/bin:$PATH"
fi
if [[ -x "$arcade_root/.tools/flutter/bin/flutter" ]]; then
  export PATH="$arcade_root/.tools/flutter/bin:$PATH"
fi
command -v cargo >/dev/null || { echo 'Install Rust stable first.' >&2; exit 1; }
case "${1:-help}" in
  test)
    cargo test --workspace --locked
    ;;
  check)
    cargo fmt --all --check
    cargo clippy --workspace --all-targets --locked -- -D warnings
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
  desktop|build-linux)
    command -v flutter >/dev/null || { echo 'Flutter is required; see docs/development.md.' >&2; exit 1; }
    [[ -f apps/flutter_app/lib/src/rust/frb_generated.dart ]] || {
      echo 'Bridge bindings are missing. Run bash scripts/dev.sh generate in a trusted Flutter environment.' >&2
      exit 1
    }
    [[ -d apps/flutter_app/linux ]] || {
      echo 'Flutter platform runners are missing. See docs/development.md before building.' >&2
      exit 1
    }
    cargo build --release --locked -p arcade_core
    export ARCADE_CORE_LIBRARY="$arcade_root/target/release/libarcade_core.so"
    cd apps/flutter_app
    if [[ "$1" == desktop ]]; then
      exec flutter run -d linux
    else
      flutter build linux --release
      cp "$ARCADE_CORE_LIBRARY" build/linux/x64/release/bundle/lib/
    fi
    ;;
  *)
    echo 'Usage: bash scripts/dev.sh {test|check|relay|driver|smoke|generate|desktop|build-linux}'
    ;;
esac
