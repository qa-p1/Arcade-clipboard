#!/usr/bin/env python3
"""Verify Clipboard's packaged installer through Link's isolated e2e runner."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def resident_processes(runtime):
    """Processes running Clipboard's Flutter runner from an unpacked copy under `runtime` (Link U1), by pid and
    the copy's folder."""
    pattern = re.compile(re.escape(str(runtime)) + r"/(clipboard-[0-9][^/]*-[0-9a-f]{16})/usr/lib/arcade-clipboard/clipboard$")
    found = {}
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            match = pattern.match(os.readlink(proc / "exe"))
        except OSError:
            continue
        if match:
            found[int(proc.name)] = match.group(1)
    return found


def wait_for(condition, what, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(0.2)
    raise AssertionError(f"Timed out waiting for {what}")


def resident_runs_from_copy(installed, cli, env, runtime, version):
    """U1 (D8): a resident start copies the image once to <data>/arcade/runtime/clipboard-<version>-<key>/, runs the
    Flutter runner from there and the launcher that started it exits 0, so no AppImage runtime or mount stays
    behind. One-shot commands and --restart's successor follow the same rule. The resident is stopped at the end."""
    with tempfile.TemporaryFile() as log:
        launcher = subprocess.Popen(
            [str(installed), "--background"], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        started = {}
        try:
            try:
                code = launcher.wait(timeout=120)
            except subprocess.TimeoutExpired:
                code = None
            assert code == 0, f"The launcher must hand over to the unpacked copy and exit 0 (it {'is still running' if code is None else f'exited {code}'})"
            started = wait_for(lambda: resident_processes(runtime), "the resident to run from the unpacked copy")
            assert len(started) == 1, started
            ((pid, copy),) = started.items()
            assert copy.startswith(f"clipboard-{version}-"), copy
            assert (runtime / copy / ".complete").is_file(), "The unpacked copy is not complete"
            # Nothing the resident maps comes from the image's mount or extraction folder.
            maps = Path(f"/proc/{pid}/maps").read_text(encoding="utf-8")
            assert ".mount_" not in maps and "appimage_extracted_" not in maps, "The resident still maps the AppImage"
            # It answers on the Link, and a Restart replaces it by another resident from the same copy.
            def status():
                answer = subprocess.run([str(cli), "--status"], env=env, text=True, encoding="utf-8",
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
                return answer.returncode == 0 and json.loads(answer.stdout)["running"] is True
            wait_for(status, "the resident to answer --status")
            restart = subprocess.run([str(cli), "--restart"], env=env, text=True, encoding="utf-8",
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            assert restart.returncode == 0 and restart.stderr == "", restart
            successor = wait_for(lambda: {p: c for p, c in resident_processes(runtime).items() if p != pid} or None,
                                 "the restarted resident to run from the unpacked copy")
            assert set(successor.values()) == {copy}, successor
            wait_for(lambda: not Path(f"/proc/{pid}").exists(), "the first resident to exit")
            wait_for(status, "the restarted resident to answer --status")
            quit_ = subprocess.run([str(cli), "--quit"], env=env, text=True, encoding="utf-8",
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            assert quit_.returncode == 0, quit_
            wait_for(lambda: not resident_processes(runtime), "the resident to quit", seconds=30)
        except BaseException:
            log.seek(0)
            print(log.read().decode(errors="replace")[-4000:], file=sys.stderr)
            raise
        finally:
            for pid in resident_processes(runtime):
                os.kill(pid, signal.SIGKILL)
            try:
                os.killpg(launcher.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            launcher.wait()


def main():
    if os.environ.get("ARCADE_E2E_INNER") != "1":
        raise SystemExit("Run this through Arcade Link tools/e2e.py run --")
    image = Path(sys.argv[1]).resolve(strict=True)
    expected_version = sys.argv[2]
    with tempfile.TemporaryDirectory(prefix="clipboard-install-", dir=os.environ["ARCADE_E2E_ROOT"]) as temporary:
        root = Path(temporary).resolve()
        assert all(not (parent / ".git").exists() for parent in (root, *root.parents))
        env = os.environ.copy()
        for key in ("APPIMAGE", "APPDIR", "ARCADE_DEV_BUILD", "ARCADE_UNPACKED", "LD_LIBRARY_PATH"):
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
        # A fresh install starts at login, like every Arcade app.
        autostart = Path(integration["autostart"])
        assert autostart == install_home / ".config/autostart/arcade-clipboard.desktop", integration
        icons = [Path(path) for path in integration["icons"]]
        entries = [installed, desktop, cli, autostart, *icons]
        assert icons, "No installed icons"
        for path in entries:
            assert path.is_relative_to(root) and path.exists(), path
        assert cli == install_home / ".local/bin/arcade-clipboard" and cli.is_symlink()
        assert cli.resolve() == installed
        assert "X-Arcade-Id=arcade.clipboard" in desktop.read_text(encoding="utf-8")
        assert run("arcade-clipboard", "--version").strip() == f"Arcade Clipboard {expected_version}"
        # CB-5: --status answers from the core before GTK and the engine start, so it works without a display
        # and prints nothing else.
        headless = {key: value for key, value in env.items() if key not in ("DISPLAY", "WAYLAND_DISPLAY")}
        answer = subprocess.run(
            [str(cli), "--status"], env=headless, text=True, encoding="utf-8",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
        )
        assert answer.returncode == 0 and answer.stderr == "", answer
        assert answer.stdout.count("\n") == 1, answer.stdout
        line = json.loads(answer.stdout)
        assert line["app"] == "arcade.clipboard" and line["version"] == expected_version, line
        assert line["running"] is False and line["link"] in ("on", "off", "unregistered"), line
        resident_runs_from_copy(installed, cli, env, Path(env["XDG_DATA_HOME"]) / "arcade/runtime", expected_version)
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
        print("Clipboard AppImage install, channel, receipt, launcher, icons, CLI, resident from the unpacked copy, repair and uninstall passed (isolated CI smoke)")


if __name__ == "__main__":
    main()
