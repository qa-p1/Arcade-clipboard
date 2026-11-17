#!/usr/bin/env python3
"""Tier 1 (headless Hyprland, Link's desktop harness) for Arcade Clipboard's windows.

    clipboard_desktop.py <AppImage>

In a private profile, from the AppImage the way a user starts it (it hands over to its unpacked copy), with a private
unlocked Secret Service when the session has none (the history key lives there; a profile does not open without it):
- ID-1: the window's class is `dev.arcade.Clipboard`; the picker is the same window under its own title.
- A plain start maps the main window; --status reports the resident.
- First-run setup by keyboard ("Start on this device" with the pre-filled name) creates the mesh: the picker only
  opens once there is a history to pick from.
- --overlay maps the picker floating, at its fixed size, with keyboard focus (Hyprland tiles new windows, so a
  runtime rule floats it).
- Escape closes the picker and gives back the main window it borrowed.
- --hide unmaps the main window and --show maps it again.
- --quit stops the resident and no Clipboard window is left.
Exit 0 when every check passes, 1 otherwise.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, ".arcade-link/tools/desktop")
from arcade_desktop import Desktop, DesktopError  # noqa: E402

CLASS = "dev.arcade.Clipboard"
MAIN, PICKER = "Arcade Clipboard", "Arcade Clipboard Picker"
PICKER_SIZE = (480, 520)  # desktop_adapter.dart _overlaySize
d = Desktop()
home = tempfile.mkdtemp(prefix="clipboard-desktop-")
downloads = Path(home, "Downloads")
downloads.mkdir()
app = str(downloads / "Arcade-Clipboard.AppImage")
shutil.copy2(sys.argv[1], app)
os.chmod(app, 0o755)
env = {**os.environ, "HOME": home, "XDG_CONFIG_HOME": f"{home}/.config", "XDG_DATA_HOME": f"{home}/.local/share",
       "XDG_CACHE_HOME": f"{home}/.cache", "ARCADE_HOME": f"{home}/arcade-link", "ARCADE_NO_INSTALL_PROMPT": "1"}
# The harness marks AppImages "already unpacked" so tests keep the process they start; Clipboard is followed through
# --status and the compositor instead, so it runs as a user's would. ARCADE_DATA_DIR would make it a non-unique
# development profile, so the profile is private through XDG_DATA_HOME instead.
for name in ("ARCADE_UNPACKED", "ARCADE_DATA_DIR"):
    env.pop(name, None)
log = open(d.artifact("clipboard.log"), "wb")
results = []
keyring = None


def check(name, ok, detail=""):
    results.append(("PASS" if ok else "FAIL", name, detail))
    print(f"{'PASS' if ok else 'FAIL'}: {name}{' (' + detail + ')' if detail and not ok else ''}", flush=True)
    return ok


def secret_service_running():
    out = subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=org.freedesktop.DBus",
                          "/org/freedesktop/DBus", "org.freedesktop.DBus.NameHasOwner",
                          "string:org.freedesktop.secrets"], capture_output=True, text=True, timeout=10)
    return "boolean true" in out.stdout


def start_keyring():
    """A private, unlocked gnome-keyring (tests/with-secret-service.sh does the same for the CI tests)."""
    control = Path(home, "keyring")
    control.mkdir(mode=0o700)
    process = subprocess.Popen(["gnome-keyring-daemon", "--foreground", "--unlock", "--components=secrets",
                                "--control-directory", str(control)],
                               stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT,
                               env={**os.environ, "XDG_DATA_HOME": f"{home}/.local/share"})
    process.stdin.write(b"arcade-synthetic-test-password")
    process.stdin.close()
    d.wait(secret_service_running, 15, "the Secret Service")
    return process


def run(*args, timeout=60):
    return subprocess.run([app, *args], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)


def launch(*args):
    # A first start keeps running as the resident (after handing over to its unpacked copy); a second one forwards
    # the action to it and exits.
    return subprocess.Popen([app, *args], env=env, stdout=log, stderr=subprocess.STDOUT)


def status():
    out = subprocess.run([app, "--status"], env=env, capture_output=True, text=True, timeout=30)
    try:
        return json.loads(out.stdout.strip().splitlines()[-1])
    except (IndexError, ValueError):
        return {}


def window(title):
    return next((c for c in d.clients() if c.get("class") == CLASS and c.get("title") == title), None)


def main_window():
    # "Arcade Clipboard", or "<Page> — Arcade Clipboard" once a mesh exists.
    return next((c for c in d.clients() if c.get("class") == CLASS and c.get("title") != PICKER
                 and c.get("title", "").endswith(MAIN)), None)


def press(address, key, times=1):
    for _ in range(times):
        d.send_shortcut(address, "", key)
        time.sleep(0.3)


def wait_for(probe, what, timeout=15):
    try:
        return d.wait(probe, timeout, what)
    except DesktopError:
        return None


def active():
    try:
        return json.loads(d.hyprctl("-j", "activewindow")).get("address")
    except (DesktopError, ValueError):
        return None


try:
    if not secret_service_running():
        keyring = start_keyring()

    # --- the main window ---------------------------------------------------------------------------------------
    launch()
    main = wait_for(main_window, "the main window", 45)
    if not check("a plain start maps the main window", main is not None):
        raise SystemExit(1)
    check("ID-1: the window's class is Clipboard's desktop id", main.get("class") == CLASS, main.get("class", ""))
    resident = wait_for(lambda: status() if status().get("running") else None, "--status", 15) or status()
    check("--status reports the running Clipboard", bool(resident.get("running")), json.dumps(resident))

    # --- first-run setup --------------------------------------------------------------------------------------------
    # Tab reaches the "Start on this device" card; in its form the name is pre-filled, and five Tabs (the name, the
    # copy switch's row and switch, Back) reach the "Start on this device" button. A mesh changes the window title to
    # "<page> — Arcade Clipboard".
    d.focus(main["address"])
    time.sleep(0.5)
    press(main["address"], "Tab")
    press(main["address"], "Return")
    time.sleep(1)
    press(main["address"], "Tab", 5)
    press(main["address"], "Return")
    check("setup by keyboard creates the mesh",
          wait_for(lambda: (main_window() or {}).get("title", MAIN) != MAIN, "the mesh", 20) is not None,
          (main_window() or {}).get("title", "no main window"))

    # --- the picker ----------------------------------------------------------------------------------------------
    d.clipboard_set("Arcade desktop test clip")
    time.sleep(1)
    run("--overlay")
    picker = wait_for(lambda: window(PICKER), "the picker")
    if check("--overlay maps the picker", picker is not None):
        check("ID-1: the picker keeps Clipboard's class", picker.get("class") == CLASS)
        check("the picker floats", bool(picker.get("floating")), json.dumps(picker.get("floating")))
        size = tuple(picker.get("size", (0, 0)))
        check("the picker has its fixed size", all(abs(a - b) <= 2 for a, b in zip(size, PICKER_SIZE)), str(size))
        check("the picker has keyboard focus",
              wait_for(lambda: active() == picker["address"], "picker focus", 5) is not None, f"active {active()}")
        check("the main window is not shown next to the picker", main_window() is None)
        d.escape(picker["address"])
        check("Escape closes the picker", wait_for(lambda: window(PICKER) is None, "the picker to close", 5)
              is not None)
        check("closing the picker gives back the main window", wait_for(main_window, "the main window", 10)
              is not None)

    # --- hide and show -------------------------------------------------------------------------------------------
    run("--hide")
    check("--hide unmaps the main window", wait_for(lambda: main_window() is None, "the window to hide", 10)
          is not None)
    run("--show")
    check("--show maps it again", wait_for(main_window, "the window to show", 15) is not None)

    # --- quit ----------------------------------------------------------------------------------------------------
    run("--quit")
    check("--quit stops Clipboard", wait_for(lambda: not status().get("running"), "Clipboard to quit", 20)
          is not None)
    check("no Clipboard window is left after --quit",
          wait_for(lambda: d.find_window(cls=CLASS) is None, "Clipboard's windows to go", 10) is not None)
finally:
    subprocess.run([app, "--quit"], env=env, capture_output=True, timeout=30)
    if keyring:
        keyring.terminate()
    log.flush()
    failed = [r for r in results if r[0] == "FAIL"]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed", flush=True)
    if failed:  # Also when a check stopped the run early.
        print(Path(d.artifact("clipboard.log")).read_text(errors="replace")[-6000:], flush=True)

sys.exit(1 if failed else 0)
