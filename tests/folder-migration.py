#!/usr/bin/env python3
"""Check the 0.3.0 folder move on Linux with a profile left by 0.2.

    xvfb-run -a python3 tests/folder-migration.py apps/flutter_app/build/linux/x64/release/bundle/clipboard

Builds an isolated home with Clipboard 0.2's data folder
(~/.local/share/dev.arcade.clipboard, Flutter's preferences inside), runs the
bundle's `--arcade-manifest`, and checks that the data moved to
~/.local/share/arcade/clipboard, the settings to
~/.config/arcade/clipboard/settings.json, the old folder is gone and the
user's shortcut survived.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> int:
    bundle = Path(sys.argv[1]).resolve()
    # A portal the app activates may leave a mount in the runtime folder.
    with tempfile.TemporaryDirectory(prefix="clipboard-migration-", ignore_cleanup_errors=True) as temp:
        home = Path(temp) / "home"
        old = home / ".local/share/dev.arcade.clipboard"
        (old / "keys").mkdir(parents=True)
        (old / "keys/device").write_bytes(b"identity")
        (old / "history.sqlite").write_bytes(b"history")
        (old / "shared_preferences.json").write_text(json.dumps({
            "flutter.device_name": "Old laptop",
            "flutter.mesh_shortcut": "CTRL+SHIFT+SPACE",
            "flutter.link_disabled_peers": ["arcade.box"],
        }))
        runtime = Path(temp) / "run"
        runtime.mkdir(mode=0o700)
        env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "XDG_RUNTIME_DIR": str(runtime)}
        # Under Link's tools/e2e.py the session bus and runtime folder are
        # already isolated; reuse them.
        for key in ("DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"):
            if key in os.environ:
                env[key] = os.environ[key]
        result = subprocess.run([str(bundle), "--arcade-manifest"], env=env, capture_output=True, text=True, timeout=120)
        assert result.returncode == 0, result.stderr
        manifest = json.loads(result.stdout)
        accelerators = [s.get("accelerator") for s in manifest.get("shortcuts", [])]
        assert "CTRL+SHIFT+SPACE" in accelerators, f"the old shortcut was lost: {accelerators}"

        new = home / ".local/share/arcade/clipboard"
        assert not old.exists(), "the old folder is still there"
        assert (new / "keys/device").read_bytes() == b"identity"
        assert (new / "history.sqlite").read_bytes() == b"history"
        assert not (new / "shared_preferences.json").exists(), "Flutter's preferences were not removed"
        settings = json.loads((home / ".config/arcade/clipboard/settings.json").read_text())
        assert settings["device_name"] == "Old laptop" and settings["link_disabled_peers"] == ["arcade.box"], settings
    print("folder migration: data, settings and shortcut moved from dev.arcade.clipboard")
    return 0


if __name__ == "__main__":
    sys.exit(main())
