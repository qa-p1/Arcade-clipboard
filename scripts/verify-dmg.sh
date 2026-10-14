#!/usr/bin/env bash
# CI only, not a real desktop: Clipboard's DMG lifecycle with an isolated home.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <image.dmg> <bundle-version> [release-version]" >&2
  exit 2
fi
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -s)" == Darwin ]] || {
  echo 'Run this only on the macOS GitHub Actions runner.' >&2
  exit 1
}
: "${RUNNER_TEMP:?macOS CI runner temporary directory is required}"
image=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
version=$2
release_version=${3:-$version}
root=$(mktemp -d "$RUNNER_TEMP/clipboard-dmg.XXXXXX")
mount="$root/mount"
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then
    hdiutil detach "$mount" >/dev/null || return 1
  fi
  rm -rf -- "$root"
}
trap cleanup EXIT
mkdir -p "$mount" "$root/home" "$root/config" "$root/data" "$root/cache" "$root/run"
chmod 700 "$root/run"
# Process-scoped only. Link treats ARCADE_HOME as home when it is supplied.
export HOME="$root/home" ARCADE_HOME="$root/arcade" ARCADE_DATA_DIR="$root/profile"
export XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" XDG_CACHE_HOME="$root/cache" XDG_RUNTIME_DIR="$root/run"
export ARCADE_NO_INSTALL_PROMPT=1
hdiutil attach "$image" -readonly -nobrowse -mountpoint "$mount" >/dev/null
mounted=1
source_app="$mount/Arcade Clipboard.app"
[[ -L "$mount/Applications" && "$(readlink "$mount/Applications")" == /Applications ]]
plutil -lint "$source_app/Contents/Info.plist"
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$source_app/Contents/Info.plist")
[[ -x "$source_app/Contents/MacOS/$executable" ]]
lipo "$source_app/Contents/MacOS/$executable" -verify_arch arm64 x86_64
lipo "$source_app/Contents/Frameworks/libarcade_core.dylib" -verify_arch arm64 x86_64
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")" == "$version" ]]
run_cli() {
  python3 - "$@" <<'PY'
import subprocess
import sys

sys.exit(subprocess.run(sys.argv[1:], timeout=30).returncode)
PY
}
run_cli "$source_app/Contents/MacOS/$executable" --install --silent --no-launch --channel nightly
installed="$ARCADE_HOME/Applications/Arcade Clipboard.app"
[[ -x "$installed/Contents/MacOS/$executable" ]]
cmp "$source_app/Contents/MacOS/$executable" "$installed/Contents/MacOS/$executable"
cmp "$source_app/Contents/Frameworks/libarcade_core.dylib" "$installed/Contents/Frameworks/libarcade_core.dylib"
plutil -lint "$installed/Contents/Info.plist"
run_cli "$installed/Contents/MacOS/$executable" --version > "$root/version.txt"
run_cli "$installed/Contents/MacOS/$executable" --integration-status > "$root/status.json"
python3 - "$ARCADE_HOME/installs/arcade.clipboard.json" "$installed" "$release_version" "$executable" "$root" <<'PY'
import json
from pathlib import Path
import sys

receipt = json.loads(Path(sys.argv[1]).read_text())
installed, version, executable, root = Path(sys.argv[2]), sys.argv[3], sys.argv[4], Path(sys.argv[5])
assert receipt['schema'] == 1 and receipt['id'] == 'arcade.clipboard'
assert receipt['method'] == 'macos-bundle' and receipt['managedBy'] == 'self'
assert receipt['version'] == version and Path(receipt['path']) == installed
assert receipt['channel'] == 'nightly'
cli = Path(receipt['integration']['cli'])
assert cli == installed.parent.parent / '.local/bin/arcade-clipboard'
assert cli.is_symlink() and cli.resolve(strict=True) == (installed / 'Contents/MacOS' / executable).resolve()
assert (root / 'version.txt').read_text().strip() == f'Arcade Clipboard {version}'
status = json.loads((root / 'status.json').read_text())
assert status['receipt'] == receipt and status['entries'] and all(entry['exists'] for entry in status['entries'])
assert not list(installed.parent.glob('.arcade-*')), 'Installer retained its staging directory'
PY
cli="$ARCADE_HOME/.local/bin/arcade-clipboard"
rm "$cli"
run_cli "$installed/Contents/MacOS/$executable" --repair
[[ -L "$cli" && -x "$cli" ]]
mkdir -p "$ARCADE_DATA_DIR"
printf 'preserve\n' > "$ARCADE_DATA_DIR/sentinel"
run_cli "$installed/Contents/MacOS/$executable" --uninstall --silent
[[ ! -e "$installed" && ! -e "$ARCADE_HOME/installs/arcade.clipboard.json" && ! -e "$cli" && ! -L "$cli" ]]
[[ "$(cat "$ARCADE_DATA_DIR/sentinel")" == preserve ]]
run_cli "$source_app/Contents/MacOS/$executable" --install --silent --no-launch
run_cli "$installed/Contents/MacOS/$executable" --uninstall --silent --remove-data
[[ ! -e "$installed" && ! -e "$ARCADE_HOME/installs/arcade.clipboard.json" && ! -e "$cli" && ! -L "$cli" && ! -e "$ARCADE_DATA_DIR" ]]
for profile_home in "$HOME" "$ARCADE_HOME"; do
  [[ ! -e "$profile_home/.zprofile" && ! -e "$profile_home/.bash_profile" && ! -e "$profile_home/.profile" ]]
done
echo 'macOS DMG install, channel, receipt, CLI, repair, uninstall and data retention passed (CI only, not a real desktop).'
