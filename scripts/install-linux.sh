#!/usr/bin/env bash
set -euo pipefail
arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arcade_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$arcade_script_dir/clipboard" ]]; then
  arcade_bundle="$arcade_script_dir"
else
  arcade_bundle="${1:-$arcade_root/apps/flutter_app/build/linux/x64/release/bundle}"
fi
arcade_install="${XDG_DATA_HOME:-$HOME/.local/share}/arcade-clipboard"
arcade_desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
[[ -x "$arcade_bundle/clipboard" ]] || { echo 'Run bash scripts/dev.sh build-linux first.' >&2; exit 1; }
mkdir -p "$arcade_install" "$arcade_desktop_dir"
cp -a "$arcade_bundle/." "$arcade_install/"
python3 - "$arcade_install" "$arcade_desktop_dir" <<'PY'
from pathlib import Path
import sys
install, applications = map(Path, sys.argv[1:])
executable = str(install / 'clipboard')
quoted = executable.replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%')
desktop = applications / 'dev.arcade.clipboard.desktop'
if desktop.exists():
    desktop.with_suffix('.desktop.bak').write_bytes(desktop.read_bytes())
desktop.write_text('[Desktop Entry]\nType=Application\nName=Arcade Clipboard\nComment=Clipboard history for your devices\nExec="' + quoted + '"\nTerminal=false\nCategories=Utility;\nStartupWMClass=dev.arcade.clipboard\n')
PY
if command -v desktop-file-validate >/dev/null; then
  desktop-file-validate "$arcade_desktop_dir/dev.arcade.clipboard.desktop"
fi
echo "Installed at $arcade_install"
