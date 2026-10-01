#!/usr/bin/env bash
# Restore a missing platform runner without overwriting customized runners.
set -euo pipefail
arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v flutter >/dev/null || { echo 'Flutter is required.' >&2; exit 1; }
arcade_template="$(mktemp -d)"
trap 'rm -rf "$arcade_template"' EXIT
flutter create --no-pub --org dev.arcade --project-name clipboard \
  --platforms linux,windows,macos,android,ios "$arcade_template/clipboard"
for arcade_platform in linux windows macos android ios; do
  if [[ -e "$arcade_root/apps/flutter_app/$arcade_platform" ]]; then
    echo "Keeping existing $arcade_platform runner."
  else
    cp -R "$arcade_template/clipboard/$arcade_platform" "$arcade_root/apps/flutter_app/"
  fi
done
echo 'Platform runner templates created. Mobile extension registration/signing remains a native integration gate.'
