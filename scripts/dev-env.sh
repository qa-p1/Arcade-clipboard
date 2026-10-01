#!/usr/bin/env bash
# Source this file to use the repository-local Rust and Flutter SDKs.
# It intentionally does not edit shell startup files or the system PATH.

_arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v cargo >/dev/null && [[ -x "${_arcade_root}/.tools/cargo/bin/cargo" ]]; then
  export RUSTUP_HOME="${_arcade_root}/.tools/rustup"
  export CARGO_HOME="${_arcade_root}/.tools/cargo"
  export PATH="${CARGO_HOME}/bin:${PATH}"
fi
if ! command -v flutter >/dev/null && [[ -x "${_arcade_root}/.tools/flutter/bin/flutter" ]]; then
  export PATH="${_arcade_root}/.tools/flutter/bin:${PATH}"
fi
if [[ -x "${_arcade_root}/.tools/codegen/bin/flutter_rust_bridge_codegen" ]]; then
  export PATH="${_arcade_root}/.tools/codegen/bin:${PATH}"
fi
