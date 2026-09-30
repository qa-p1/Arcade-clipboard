#!/usr/bin/env bash
# Build the iOS device-only Rust static archive consumed by setup-ios.rb.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rust_bridge="${repo_root}/core/rust/src/frb_generated.rs"
dart_bridge="${repo_root}/apps/flutter_app/lib/src/rust/frb_generated.dart"
archive="${repo_root}/target/aarch64-apple-ios/release/libarcade_core.a"

command -v cargo >/dev/null 2>&1 || {
  echo 'Rust/Cargo is required to build the iOS core.' >&2
  exit 1
}

if [[ ! -f "${rust_bridge}" || ! -f "${dart_bridge}" ]]; then
  cat >&2 <<'EOF'
Generated Flutter Rust Bridge bindings are missing. On a trusted Flutter/Rust
development machine, run `flutter_rust_bridge_codegen generate` from the
repository root, then rerun this script. This script does not generate Flutter
bindings or invoke Flutter.
EOF
  exit 1
fi

if ! rustup target list --installed 2>/dev/null | grep -Fxq 'aarch64-apple-ios'; then
  echo 'The Rust iOS device target is missing; install it with `rustup target add aarch64-apple-ios`.' >&2
  exit 1
fi

cd "${repo_root}"
cargo build --locked --release -p arcade_core --target aarch64-apple-ios

if [[ ! -s "${archive}" ]]; then
  echo "Cargo succeeded but the expected archive is missing: ${archive}" >&2
  exit 1
fi

echo "Built iOS device archive: ${archive}"
