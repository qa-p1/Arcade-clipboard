#!/usr/bin/env bash
set -euo pipefail
arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$arcade_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'The iPhone build needs macOS and Xcode. Use the GitHub IPA workflow from Linux.' >&2; exit 1; }
source scripts/dev-env.sh
command -v xcodebuild >/dev/null
command -v ruby >/dev/null
ruby -e "require 'xcodeproj'" || { echo 'Install xcodeproj: gem install xcodeproj --version 1.28.1 --no-document' >&2; exit 1; }
(cd apps/flutter_app && flutter pub get --enforce-lockfile)
ruby scripts/setup-ios.rb
bash scripts/build-ios-core.sh aarch64-apple-ios
arcade_build_arguments=(--release --no-codesign)
if [[ -n "${ARCADE_BUILD_NUMBER:-}" ]]; then
  [[ "$ARCADE_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo 'ARCADE_BUILD_NUMBER must be numeric.' >&2; exit 1; }
  arcade_build_arguments+=(--build-number "$ARCADE_BUILD_NUMBER")
fi
(cd apps/flutter_app && flutter build ios "${arcade_build_arguments[@]}")
python3 scripts/package-ios.py \
  apps/flutter_app/build/ios/iphoneos/Runner.app dist/Arcade-Clipboard-iOS-unsigned.ipa
