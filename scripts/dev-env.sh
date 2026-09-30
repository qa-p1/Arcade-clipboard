#!/usr/bin/env bash
# Source this file to use the repository-local Rust and Flutter SDKs.
# It intentionally does not edit shell startup files or the system PATH.

_arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RUSTUP_HOME="${_arcade_root}/.tools/rustup"
export CARGO_HOME="${_arcade_root}/.tools/cargo"
export FLUTTER_ROOT="${_arcade_root}/.tools/flutter"
export RUSTUP_TOOLCHAIN="1.98.1"
export PATH="${CARGO_HOME}/bin:${FLUTTER_ROOT}/bin:${PATH}"

if [[ ! -x "${CARGO_HOME}/bin/cargo" ]]; then
  echo "Rust is not installed. Run scripts/bootstrap-toolchains.sh first." >&2
  return 1 2>/dev/null || exit 1
fi
if [[ ! -x "${FLUTTER_ROOT}/bin/flutter" ]]; then
  echo "Flutter is not installed. Run scripts/bootstrap-toolchains.sh first." >&2
  return 1 2>/dev/null || exit 1
fi
