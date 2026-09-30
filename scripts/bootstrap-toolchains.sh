#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${ROOT}/.tools"
DOWNLOADS="${TOOLS}/downloads"

# Reproducible stable versions selected from the official release channels on
# 2026-09-30. All installations stay inside .tools; this script never changes
# user shell configuration or the system PATH.
RUST_VERSION="1.98.1"
FLUTTER_VERSION="3.47.5"
FLUTTER_ARCHIVE="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
FLUTTER_SHA256="2132e990f236f8d22e7c6314b29a191a95b10d7cbcfec9b4e2e303d996652cbb"

mkdir -p "${DOWNLOADS}" "${TOOLS}/rustup" "${TOOLS}/cargo"

if [[ ! -x "${TOOLS}/cargo/bin/rustup" ]]; then
  curl -fsSL https://sh.rustup.rs -o "${DOWNLOADS}/rustup-init.sh"
  RUSTUP_HOME="${TOOLS}/rustup" CARGO_HOME="${TOOLS}/cargo" \
    sh "${DOWNLOADS}/rustup-init.sh" -y --no-modify-path \
      --profile minimal --default-toolchain "${RUST_VERSION}" \
      --default-host x86_64-unknown-linux-gnu
else
  RUSTUP_HOME="${TOOLS}/rustup" CARGO_HOME="${TOOLS}/cargo" \
    "${TOOLS}/cargo/bin/rustup" toolchain install "${RUST_VERSION}" \
      --profile minimal
fi

if [[ ! -x "${TOOLS}/flutter/bin/flutter" ]]; then
  archive="${DOWNLOADS}/${FLUTTER_ARCHIVE}"
  curl -fL --retry 3 --retry-delay 2 \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${FLUTTER_ARCHIVE}" \
    -o "${archive}"
  echo "${FLUTTER_SHA256}  ${archive}" | sha256sum --check --status
  # Container workspaces commonly reject ownership changes even when running as
  # root, so preserve file contents/modes without asking tar to chown files.
  tar --no-same-owner -xJf "${archive}" -C "${TOOLS}"
fi

source "${ROOT}/scripts/dev-env.sh"
rustc --version
cargo --version
flutter --version
