#!/usr/bin/env bash
set -euo pipefail
arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$arcade_root"
source scripts/dev-env.sh
if ! pkg-config --exists keybinder-3.0 && [[ -f .tools/native/usr/lib/pkgconfig/keybinder-3.0.pc ]]; then
  export PKG_CONFIG_PATH="$arcade_root/.tools/native/usr/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
pkg-config --exists gtk+-3.0 keybinder-3.0 || {
  echo 'Install GTK 3 and keybinder development packages; see docs/development.md.' >&2; exit 1;
}
(cd apps/flutter_app && flutter pub get --enforce-lockfile && flutter build linux --release)
arcade_bundle="$arcade_root/apps/flutter_app/build/linux/x64/release/bundle"
arcade_keybinder_dir="$(pkg-config --variable=libdir keybinder-3.0)"
# This small dependency is absent on some Wayland desktops. Include its SONAME
# so the relocatable bundle also starts without a custom LD_LIBRARY_PATH.
cp -L "$arcade_keybinder_dir/libkeybinder-3.0.so.0" "$arcade_bundle/lib/"
mkdir -p "$arcade_bundle/data/licenses"
cp platform/desktop/licenses/keybinder.txt "$arcade_bundle/data/licenses/keybinder.txt"
for arcade_license in /usr/share/doc/libkeybinder-3.0-0/copyright \
  /usr/share/licenses/keybinder3/COPYING "$arcade_root/.tools/native/usr/share/licenses/keybinder3/COPYING"; do
  if [[ -f "$arcade_license" ]]; then
    cp "$arcade_license" "$arcade_bundle/data/licenses/keybinder.txt"
    break
  fi
done
python3 - "$arcade_bundle" <<'PY'
from pathlib import Path
import subprocess, sys
bundle = Path(sys.argv[1])
for file in [bundle / 'clipboard', *sorted((bundle / 'lib').glob('*.so*'))]:
    output = subprocess.run(['ldd', str(file)], text=True, capture_output=True).stdout
    if 'not found' in output:
        raise SystemExit(f'Runtime dependency missing for {file.name}:\n{output}')
(bundle / 'START.txt').write_text(
    'Arcade Clipboard\n\nRun ./clipboard (or ./arcade-clipboard) from this folder.\n'
    'Keep the data/ and lib/ folders beside the executable.\n'
    'Linux needs GTK 3 and an unlocked Secret Service keyring.\n'
    'Hyprland automatic paste needs hyprctl, wl-copy and wl-paste.\n'
    'Other Wayland desktops provide a clipboard picker with copy fallback.\n'
)
PY
mkdir -p dist
tar -C "$arcade_bundle" -czf dist/Arcade-Clipboard-linux-x64.tar.gz .
sha256sum dist/Arcade-Clipboard-linux-x64.tar.gz > dist/Arcade-Clipboard-linux-x64.tar.gz.sha256
echo "Linux app: $arcade_bundle/clipboard"
echo "Archive: $arcade_root/dist/Arcade-Clipboard-linux-x64.tar.gz"
