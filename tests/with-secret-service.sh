#!/usr/bin/env bash
# Starts an isolated Linux Secret Service for synthetic integration tests.
# Run as: dbus-run-session -- bash tests/with-secret-service.sh
set -euo pipefail
arcade_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$arcade_root"
command -v gnome-keyring-daemon >/dev/null
command -v dbus-send >/dev/null
arcade_test_state="$(mktemp -d)"
export XDG_DATA_HOME="$arcade_test_state/data"
export XDG_RUNTIME_DIR="$arcade_test_state/run"
mkdir -m 700 -p "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR/keyring"
printf '%s' 'arcade-synthetic-test-password' | gnome-keyring-daemon \
  --foreground --unlock --components=secrets \
  --control-directory "$XDG_RUNTIME_DIR/keyring" >"$arcade_test_state/keyring.log" 2>&1 &
arcade_keyring_pid=$!
cleanup() {
  kill "$arcade_keyring_pid" 2>/dev/null || true
  wait "$arcade_keyring_pid" 2>/dev/null || true
  rm -rf "$arcade_test_state"
}
trap cleanup EXIT
arcade_ready=false
for arcade_attempt in {1..50}; do
  if dbus-send --session --print-reply --dest=org.freedesktop.DBus \
    /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
    string:org.freedesktop.secrets 2>/dev/null | rg -q 'boolean true'; then
    arcade_ready=true
    break
  fi
  sleep 0.1
done
if [[ "$arcade_ready" != true ]]; then
  cat "$arcade_test_state/keyring.log" >&2
  echo 'Isolated Secret Service did not start.' >&2
  exit 1
fi
python3 tests/process_smoke.py --data-dir "$arcade_test_state/profiles"
