#!/usr/bin/env bash
set -euo pipefail
arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$arcade_root"
source scripts/dev-env.sh
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-3}"
cargo build --release --locked -p arcade_core
arcade_app="$arcade_root/apps/flutter_app/build/macos/Build/Products/${1:-Release}/Arcade Clipboard.app"
[[ -d "$arcade_app" ]] || { echo 'Build the Flutter macOS app first.' >&2; exit 1; }
mkdir -p "$arcade_app/Contents/Frameworks"
cp target/release/libarcade_core.dylib "$arcade_app/Contents/Frameworks/"
install_name_tool -id '@rpath/libarcade_core.dylib' "$arcade_app/Contents/Frameworks/libarcade_core.dylib"
codesign --force --sign - "$arcade_app/Contents/Frameworks/libarcade_core.dylib"
codesign --force --deep --sign - "$arcade_app"
echo "Built $arcade_app"
