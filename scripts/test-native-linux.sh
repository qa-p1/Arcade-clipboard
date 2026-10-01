#!/usr/bin/env bash
set -euo pipefail
arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$arcade_root"
source scripts/dev-env.sh
[[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || {
  echo 'This acceptance test needs a running Hyprland session.' >&2; exit 1;
}
mkdir -p .verification/screenshots .verification/bin
cc -Wall -Wextra -Werror tests/native_paste_target.c -o .verification/bin/paste-target \
  $(pkg-config --cflags --libs gtk+-3.0)
cargo build --locked -p arcade_test_driver
export ARCADE_TEST_DRIVER="$arcade_root/target/debug/arcade_test_driver"
export ARCADE_PASTE_TEST_TARGET="$arcade_root/.verification/bin/paste-target"
export ARCADE_SCREENSHOT_DIR="$arcade_root/.verification/screenshots"
dbus-run-session -- bash tests/with-secret-service.sh \
  bash -c 'cd apps/flutter_app && flutter test integration_test/native_app_test.dart -d linux'
