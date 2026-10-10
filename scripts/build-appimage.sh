#!/usr/bin/env bash
# Assemble the Flutter Linux release bundle as dist/Arcade-Clipboard-<version>-x86_64.AppImage.
set -euo pipefail
arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$arcade_root"

usage() {
  echo 'Usage: bash scripts/dev.sh build-appimage --version VERSION [--bundle PATH] [--output-dir PATH]' >&2
  exit 2
}

version=''
bundle="$arcade_root/apps/flutter_app/build/linux/x64/release/bundle"
output_dir="$arcade_root/dist"
while (($#)); do
  case "$1" in
    --version) (($# >= 2)) || usage; version=$2; shift 2 ;;
    --bundle) (($# >= 2)) || usage; bundle=$2; shift 2 ;;
    --output-dir) (($# >= 2)) || usage; output_dir=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$version" =~ ^[0-9][0-9A-Za-z.+-]*$ ]] || usage
[[ -x "$bundle/clipboard" && -x "$bundle/arcade-clipboard" && -d "$bundle/lib" && -d "$bundle/data" ]] || {
  echo "Missing Flutter release bundle at $bundle; run bash scripts/dev.sh build-linux first." >&2
  exit 1
}
command -v curl >/dev/null || { echo 'curl is required to download appimagetool.' >&2; exit 1; }
command -v sha256sum >/dev/null || { echo 'sha256sum is required to verify appimagetool.' >&2; exit 1; }
command -v rsvg-convert >/dev/null || { echo 'rsvg-convert is required to render the hicolor icons (install librsvg2-bin).' >&2; exit 1; }

arch=x86_64
tool_version=1.9.0
tool_sha256=46fdd785094c7f6e545b61afcfb0f3d98d8eab243f644b4b17698c01d06083d1
tool_url="https://github.com/AppImage/appimagetool/releases/download/$tool_version/appimagetool-$arch.AppImage"
tool="$arcade_root/target/tools/appimagetool-$tool_version-$arch.AppImage"
mkdir -p "$(dirname "$tool")" "$output_dir"
if ! echo "$tool_sha256  $tool" | sha256sum -c --status 2>/dev/null; then
  rm -f "$tool" "$tool.part"
  curl -fsSL --retry 3 -o "$tool.part" "$tool_url"
  echo "$tool_sha256  $tool.part" | sha256sum -c -
  chmod 755 "$tool.part"
  mv "$tool.part" "$tool"
fi

appdir=$(mktemp -d "${TMPDIR:-/tmp}/arcade-clipboard.AppDir.XXXXXX")
trap 'rm -rf "$appdir"' EXIT
bundle="$(cd "$bundle" && pwd)"
mkdir -p \
  "$appdir/usr/lib/arcade-clipboard" \
  "$appdir/usr/share/applications" \
  "$appdir/usr/share/icons/hicolor/scalable/apps" \
  "$appdir/usr/share/doc/arcade-clipboard"
cp -a "$bundle/." "$appdir/usr/lib/arcade-clipboard/"
install -m 644 packaging/linux/dev.arcade.clipboard.desktop "$appdir/dev.arcade.clipboard.desktop"
install -m 644 packaging/linux/dev.arcade.clipboard.desktop "$appdir/usr/share/applications/dev.arcade.clipboard.desktop"

icon="$arcade_root/apps/flutter_app/assets/arcade/arcade.clipboard.svg"
install -m 644 "$icon" "$appdir/usr/share/icons/hicolor/scalable/apps/dev.arcade.clipboard.svg"
for size in 16 24 32 48 64 128 256 512; do
  icon_dir="$appdir/usr/share/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$icon_dir"
  rsvg-convert --width "$size" --height "$size" "$icon" > "$icon_dir/dev.arcade.clipboard.png"
done
cp "$appdir/usr/share/icons/hicolor/256x256/apps/dev.arcade.clipboard.png" "$appdir/dev.arcade.clipboard.png"
if [[ -f LICENSE ]]; then
  install -m 644 LICENSE "$appdir/usr/share/doc/arcade-clipboard/LICENSE"
fi

cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
set -eu

# APPDIR is set by some AppImage runtimes and extraction wrappers. For direct
# execution, resolve AppRun inside the mounted or extracted AppDir. APPIMAGE
# remains untouched for the app's own runtime detection.
if [ -n "${APPDIR:-}" ] && [ -d "$APPDIR/usr/lib/arcade-clipboard" ]; then
  appdir=$APPDIR
else
  appdir=$(dirname "$(readlink -f "$0")")
  APPDIR=$appdir
  export APPDIR
fi
bundle="$appdir/usr/lib/arcade-clipboard"
LD_LIBRARY_PATH="$bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
exec "$bundle/arcade-clipboard" "$@"
APPRUN
chmod 755 "$appdir/AppRun"

if command -v desktop-file-validate >/dev/null; then
  desktop-file-validate "$appdir/dev.arcade.clipboard.desktop"
  desktop-file-validate "$appdir/usr/share/applications/dev.arcade.clipboard.desktop"
fi

python3 - "$bundle" <<'PY'
from pathlib import Path
import os
import subprocess
import sys

bundle = Path(sys.argv[1])
env = os.environ.copy()
env['LD_LIBRARY_PATH'] = str(bundle / 'lib') + (os.pathsep + env['LD_LIBRARY_PATH'] if env.get('LD_LIBRARY_PATH') else '')
files = [bundle / 'clipboard', *sorted((bundle / 'lib').glob('*.so*'))]
for file in files:
    result = subprocess.run(['ldd', str(file)], text=True, capture_output=True, env=env)
    output = result.stdout + result.stderr
    if result.returncode or 'not found' in output:
        raise SystemExit(f'Runtime dependency missing for {file.name}:\n{output}')
print(f'ldd: checked {len(files)} bundled ELF files; no missing libraries')
PY

output="$output_dir/Arcade-Clipboard-$version-$arch.AppImage"
ARCH=$arch "$tool" --appimage-extract-and-run "$appdir" "$output"
chmod 755 "$output"
echo "built $output"
