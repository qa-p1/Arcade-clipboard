#!/usr/bin/env python3
"""Verify Clipboard's packaged installer through Link's isolated e2e runner."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    if os.environ.get("ARCADE_E2E_INNER") != "1":
        raise SystemExit("Run this through Arcade Link tools/e2e.py run --")
    image = Path(sys.argv[1]).resolve(strict=True)
    expected_version = sys.argv[2]
    with tempfile.TemporaryDirectory(prefix="clipboard-install-", dir=os.environ["ARCADE_E2E_ROOT"]) as temporary:
        root = Path(temporary).resolve()
        assert all(not (parent / ".git").exists() for parent in (root, *root.parents))
        env = os.environ.copy()
        for key in ("APPIMAGE", "APPDIR", "ARCADE_DEV_BUILD", "LD_LIBRARY_PATH"):
            env.pop(key, None)
        for key, directory in (
            ("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
            ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "run"), ("ARCADE_HOME", "arcade"),
            ("ARCADE_DATA_DIR", "profile"),
        ):
            path = root / directory
            path.mkdir()
            env[key] = str(path)
        (root / "run").chmod(0o700)
        env["APPIMAGE_EXTRACT_AND_RUN"] = "1"
        env["ARCADE_NO_INSTALL_PROMPT"] = "1"
        install_home = Path(env["ARCADE_HOME"])
        env["PATH"] = str(install_home / ".local/bin") + os.pathsep + env.get("PATH", "")
        download = root / "Downloaded.AppImage"
        shutil.copy2(image, download)
        download.chmod(0o755)

        def run(executable, *args):
            result = subprocess.run(
                [str(executable), *args], env=env, text=True, encoding="utf-8",
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
            )
            if result.returncode:
                raise RuntimeError(f"{executable} {' '.join(args)} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
            return result.stdout

        assert run(download, "--version").strip() == f"Arcade Clipboard {expected_version}"
        run(download, "--install", "--silent", "--no-launch", "--channel", "nightly")
        receipt_path = install_home / "installs/arcade.clipboard.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert receipt["schema"] == 1 and receipt["id"] == "arcade.clipboard", receipt
        assert receipt["method"] == "appimage" and receipt["managedBy"] == "self", receipt
        assert receipt["version"] == expected_version and receipt["channel"] == "nightly", receipt
        installed = install_home / "Applications/Arcade/Arcade-Clipboard.AppImage"
        assert Path(receipt["path"]) == installed and os.access(installed, os.X_OK), receipt
        assert installed.read_bytes() == image.read_bytes(), "Installed package differs from the download"
        integration = receipt["integration"]
        desktop, cli = Path(integration["desktopEntry"]), Path(integration["cli"])
        assert not integration.get("autostart"), integration
        icons = [Path(path) for path in integration["icons"]]
        entries = [installed, desktop, cli, *icons]
        assert icons, "No installed icons"
        for path in entries:
            assert path.is_relative_to(root) and path.exists(), path
        assert cli == install_home / ".local/bin/arcade-clipboard" and cli.is_symlink()
        assert cli.resolve() == installed
        assert "X-Arcade-Id=arcade.clipboard" in desktop.read_text(encoding="utf-8")
        assert run("arcade-clipboard", "--version").strip() == f"Arcade Clipboard {expected_version}"
        status = json.loads(run(cli, "--integration-status"))
        assert status["receipt"] == receipt and all(entry["exists"] for entry in status["entries"]), status
        desktop.unlink()
        run(installed, "--repair")
        assert desktop.is_file(), "Repair did not restore the launcher"
        sentinel = Path(env["ARCADE_DATA_DIR"]) / "sentinel"
        sentinel.write_text("preserve", encoding="utf-8")
        run(installed, "--uninstall", "--silent")
        for path in [receipt_path, *entries]:
            assert not path.exists() and not path.is_symlink(), f"Uninstall retained {path}"
        assert sentinel.read_text(encoding="utf-8") == "preserve"
        shutil.copy2(image, download)
        run(download, "--install", "--silent", "--no-launch")
        run(installed, "--uninstall", "--silent", "--remove-data")
        assert not sentinel.parent.exists(), "Explicit data removal retained the profile"
        for profile_home in (Path(env["HOME"]), install_home):
            for name in (".profile", ".bash_profile", ".bashrc", ".zprofile", ".zshrc"):
                assert not (profile_home / name).exists(), f"Installer created {name}"
        print("Clipboard AppImage install, channel, receipt, launcher, icons, CLI, repair and uninstall passed (isolated CI smoke)")


if __name__ == "__main__":
    main()
