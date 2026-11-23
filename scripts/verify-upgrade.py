#!/usr/bin/env python3
"""Upgrade from a published Clipboard release to a new one, keeping the user's data (PLAN exit gate "Upgrade test").

    dbus-run-session -- xvfb-run -a -s "-screen 0 1280x800x24" python3 scripts/verify-upgrade.py OLD.AppImage NEW.AppImage

OLD is the previous release's published file (check it against its SHA256SUMS.txt first), NEW the candidate's. Needs
gnome-keyring, xdotool, xclip and libsecret-tools (`secret-tool`) next to the D-Bus session and X display it runs in.

Clipboard keeps its history key in the Secret Service and refuses to open a profile without it, so the test runs
its own gnome-keyring, unlocked, on the private session bus (it stops if that bus already has a Secret Service: it
would be somebody's real keyring). In a private profile (HOME, XDG_*, ARCADE_HOME; ARCADE_DATA_DIR is not set, a
user's profile is the default one):
  * OLD is installed from a download folder (`--install --silent --no-launch`, which also adds the login entry),
    started with `--background` and set up the way a first-time user does (the window's "Start on this device");
  * three clips are copied the way a user copies them (X11 selection: text, a link and a file) and OLD must capture
    them; three non-default settings are changed in OLD's Settings page (Keep history 7 days, Storage budget 1 GB,
    Appearance Dark);
  * the profile is snapshotted: history.sqlite (the rows' metadata, the mesh and device records, the settings table),
    settings.json and the Secret Service item that holds the history key (its attributes and a hash of its value).
NEW is then downloaded and installed over OLD while OLD runs, the way a user updates by hand. NEW must replace the
installed copy in place, stop OLD, report its own version, and keep one launcher and at most one login entry (both
starting the installed file), every history row, the mesh and the device, the settings, and the very same Secret
Service item (no second identity). The history is encrypted, so NEW also has to read it: the quick picker is
opened in NEW, each clip is searched for and chosen, and the clipboard must carry the original text, link and file.

A dry run against a local build of the same version sets VERIFY_UPGRADE_SAME_VERSION=1: OLD and NEW may then be the
same bytes (or the same version number); everything else is still checked.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time

APP_ID = "arcade.clipboard"
LAUNCHER = "dev.arcade.Clipboard.desktop"
AUTOSTART = "arcade-clipboard.desktop"
FILENAME = "Arcade-Clipboard.AppImage"
SAME_VERSION = os.environ.get("VERIFY_UPGRADE_SAME_VERSION") == "1"

# What a user copies: (kind Clipboard files it under, what is copied, a word the picker's search finds it by).
TEXT = "Upgrade test note: bring the kiwi report to the noon meeting"
LINK = "https://example.invalid/upgrade-test/pomelo"
FILE_NAME = "papaya-budget.txt"
FILE_CONTENT = "papaya budget\nline two of the user's file\n"
# The three settings a user changes in OLD's Settings page: the database's `settings` table (retention_hours,
# max_storage_mb; 1.0's defaults are Forever and 256 MB) and Flutter's settings.json (appearance_mode). 1.0 replaced
# 0.3's History limit (max_items) with Storage budget.
RETENTION_HOURS = "168"
MAX_STORAGE_MB = "1024"
APPEARANCE = "dark"
# Where the controls are in OLD's window (1040x740, content origin at the window's corner). Measured on 1.0.0 (the
# previous release since 2026-11-21; 0.3.2's page was laid out differently): the Settings page, scrolled down by 12
# wheel clicks for the two drop-downs, scrolled back for Appearance. A drop-down's menu opens with the current value
# over the button, so the positions of "7 days" and "1 GB" assume the defaults (Forever, 256 MB).
UI_DARK = (963, 138)
UI_KEEP_DROPDOWN, UI_KEEP_7_DAYS = (950, 72), (940, 224)
UI_BUDGET_DROPDOWN, UI_BUDGET_1_GB = (950, 137), (936, 184)
UI_SCROLL_AT = (620, 400)


class Failure(AssertionError):
    pass


def check(condition, message):
    if not condition:
        raise Failure(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def alive(pid):
    """Running, not a zombie."""
    try:
        return Path(f"/proc/{pid}/stat").read_text().rpartition(") ")[2].split()[0] != "Z"
    except OSError:
        return False


def clipboard_processes(root):
    """Processes of this profile: running a file under `root`, or started with its ARCADE_HOME."""
    found = {}
    marker = b"ARCADE_HOME=" + str(root / "arcade").encode()
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit() or int(proc.name) == os.getpid():
            continue
        try:
            exe = os.readlink(proc / "exe")
            environment = (proc / "environ").read_bytes().split(b"\0")
        except OSError:
            continue
        if (exe.startswith(str(root) + "/") or marker in environment) and alive(proc.name):
            found[int(proc.name)] = exe
    return found


def read_database(path):
    """{table: (columns, [row, ...])} for every table of the database, opened read-only."""
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
    try:
        tables = [row[0] for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
        result = {}
        for table in tables:
            cursor = connection.execute(f'SELECT * FROM "{table}"')
            result[table] = ([column[0] for column in cursor.description], cursor.fetchall())
        return result
    finally:
        connection.close()


def table_rows(database, table, *columns):
    """The rows of `table` as tuples of `columns` (all of them when none are given)."""
    names, rows = database[table]
    index = [names.index(name) for name in columns] if columns else range(len(names))
    return sorted((tuple(row[i] for i in index) for row in rows), key=repr)


def settings_table(database):
    return dict(table_rows(database, "settings"))


def meta_table(database):
    return dict(table_rows(database, "meta"))


# The columns that say which clip a row is. The ciphertext may be rewritten by a newer version (it is checked by
# reading the clip back through the picker, not by comparing bytes).
ITEM_COLUMNS = ("id", "origin_device", "sender_sequence", "source_name", "created_at", "kind", "content_tag", "pinned")


def secret_items():
    """{username: (sha256 of the secret, attributes)} of every Clipboard item in the Secret Service."""
    def gdbus(path, *call):
        result = subprocess.run(["gdbus", "call", "--session", "--dest", "org.freedesktop.secrets", "--object-path",
                                 path, "--method", *call], capture_output=True, text=True, timeout=30)
        check(result.returncode == 0, f"gdbus {' '.join(call)}: {result.stderr[-500:]}")
        return result.stdout

    found = {}
    answer = gdbus("/org/freedesktop/secrets", "org.freedesktop.Secret.Service.SearchItems",
                   "{'service': 'arcade-clipboard'}")
    for path in re.findall(r"objectpath '([^']+)'", answer):
        attributes = dict(re.findall(r"'([^']+)': '([^']*)'", gdbus(
            path, "org.freedesktop.DBus.Properties.Get", "org.freedesktop.Secret.Item", "Attributes")))
        lookup = subprocess.run(["secret-tool", "lookup", "service", "arcade-clipboard", "username",
                                 attributes["username"]], capture_output=True, timeout=30)
        check(lookup.returncode == 0 and lookup.stdout, f"The Secret Service item {attributes['username']} has no value")
        found[attributes["username"]] = (hashlib.sha256(lookup.stdout).hexdigest(), attributes)
    return found


def session_has_secret_service():
    result = subprocess.run(["gdbus", "call", "--session", "--dest", "org.freedesktop.DBus", "--object-path",
                             "/org/freedesktop/DBus", "--method", "org.freedesktop.DBus.NameHasOwner",
                             "org.freedesktop.secrets"], capture_output=True, text=True, timeout=15)
    return "true" in result.stdout


def main():
    old_image, new_image = (Path(arg).resolve(strict=True) for arg in sys.argv[1:3])
    if not SAME_VERSION:
        check(digest(old_image) != digest(new_image), "OLD and NEW are the same file")
    check(os.environ.get("DBUS_SESSION_BUS_ADDRESS"),
          "Run this inside `dbus-run-session -- xvfb-run -a -s \"-screen 0 1280x800x24\" python3 scripts/verify-upgrade.py OLD NEW`: no D-Bus session")
    check(os.environ.get("DISPLAY"), "Run this inside xvfb-run: no X display")
    for tool in ("gnome-keyring-daemon", "gdbus", "xdotool", "xclip", "secret-tool"):
        check(shutil.which(tool), f"{tool} is not installed (gnome-keyring, libglib2.0-bin, xdotool, xclip, libsecret-tools)")
    size = subprocess.run(["xdotool", "getdisplaygeometry"], capture_output=True, text=True).stdout.split()
    check(len(size) == 2 and int(size[0]) >= 1100 and int(size[1]) >= 780,
          f"The X screen is {'x'.join(size)}: the window (1040x740) must fit; use xvfb-run -s \"-screen 0 1280x800x24\"")
    check(not session_has_secret_service(),
          "This D-Bus session already has a Secret Service (a real keyring?): run under dbus-run-session")
    with tempfile.TemporaryDirectory(prefix="clipboard-upgrade-", dir=os.environ.get("RUNNER_TEMP")) as directory:
        root = Path(directory).resolve()
        for parent in (root, *root.parents):
            if (parent / ".git").exists():
                raise RuntimeError("Upgrade verification must run outside the checkout")
        env = {k: v for k, v in os.environ.items() if not k.startswith("ARCADE_") and k not in (
            "APPIMAGE", "APPDIR", "OWD", "ARGV0", "LD_LIBRARY_PATH", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE",
            "SWAYSOCK", "NIRI_SOCKET")}
        env.update(ARCADE_HOME=str(root / "arcade"), HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"),
                   XDG_DATA_HOME=str(root / "data"), XDG_CACHE_HOME=str(root / "cache"),
                   XDG_RUNTIME_DIR=str(root / "run"), TMPDIR=str(root / "tmp"), ARCADE_NO_INSTALL_PROMPT="1",
                   GDK_BACKEND="x11", APPIMAGE_EXTRACT_AND_RUN="1", LC_ALL="C.UTF-8")
        for name in ("home", "config", "data", "cache", "run", "tmp", "arcade", "run/keyring"):
            (root / name).mkdir(mode=0o700)
        downloads = root / "home/Downloads"
        downloads.mkdir()
        arcade = root / "arcade"
        installed = arcade / "Applications/Arcade" / FILENAME
        # With ARCADE_HOME set only the install lands there; the data and settings are at their XDG places.
        data = root / "data/arcade/clipboard"
        history = data / "history.sqlite"
        settings_json = root / "config/arcade/clipboard/settings.json"
        launcher = arcade / ".local/share/applications" / LAUNCHER
        autostart_folder = arcade / ".config/autostart"
        log = (root / "clipboard.log").open("w+b")
        launched = []
        keyring = []
        # Helpers that are not Clipboard (the keyring, xclip, xdotool) run without its ARCADE_HOME, so they are not
        # counted among its processes.
        helper_env = {k: v for k, v in env.items() if k != "ARCADE_HOME"}

        def download(image):
            copy = downloads / image.name
            shutil.copy2(image, copy)
            copy.chmod(0o755)
            return copy

        def run(executable, *args, check_exit=True, timeout=120):
            try:
                result = subprocess.run([str(executable), *args], env=env, capture_output=True, text=True,
                                        timeout=timeout)
            except subprocess.TimeoutExpired:
                raise Failure(f"{Path(executable).name} {' '.join(args)} did not finish in {timeout}s")
            if check_exit:
                check(result.returncode == 0, (
                    f"{Path(executable).name} {' '.join(args)} exited {result.returncode}: {result.stderr[-2000:]}"))
            return result.stdout

        def status():
            lines = [line for line in run(installed, "--status", timeout=30).splitlines() if line.startswith("{")]
            return json.loads(lines[-1])

        def wait(probe, what, seconds=30):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                if result := probe():
                    return result
                time.sleep(0.2)
            raise Failure(f"Timed out waiting for {what}")

        def running():
            try:
                info = status()
            except (AssertionError, ValueError, IndexError):
                return None
            return info if info.get("running") else None

        def start():
            launched.append(subprocess.Popen([str(installed), "--background"], env=env, stdout=log,
                                             stderr=subprocess.STDOUT, start_new_session=True))
            return wait(running, "Clipboard to report running in --status", 60)

        def stop():
            run(installed, "--quit", timeout=30)
            wait(lambda: not running() and not clipboard_processes(root) and all(p.poll() is not None for p in launched),
                 "every Clipboard process to exit after --quit", 30)

        # ---- the keyring: a private, unlocked Secret Service on this session bus -------------------------------
        def start_keyring():
            process = subprocess.Popen(["gnome-keyring-daemon", "--foreground", "--unlock", "--components=secrets",
                                        "--control-directory", str(root / "run/keyring")], env=helper_env,
                                       stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT)
            process.stdin.write(b"arcade-upgrade-test-password\n")
            process.stdin.close()
            keyring.append(process)
            wait(session_has_secret_service, "the private Secret Service", 20)
            # An unlocked default collection takes a secret; a locked one would make the app refuse its profile.
            stored = subprocess.run(["secret-tool", "store", "--label=probe", "probe", "keyring-check"], env=helper_env,
                                    input=b"x", capture_output=True, timeout=30)
            check(stored.returncode == 0, f"The private keyring is not unlocked: {stored.stderr.decode()[-500:]}")
            subprocess.run(["secret-tool", "clear", "probe", "keyring-check"], env=helper_env, capture_output=True, timeout=30)

        # ---- the desktop: windows by xdotool, copies by xclip --------------------------------------------------
        def xdotool(*args, check_exit=True):
            result = subprocess.run(["xdotool", *args], env=helper_env, capture_output=True, text=True, timeout=30)
            if check_exit:
                check(result.returncode == 0, f"xdotool {' '.join(args)}: {result.stderr[-500:]}")
            return result.stdout

        def clipboard_windows():
            found = []
            for window in xdotool("search", "--onlyvisible", "--class", "dev.arcade.Clipboard",
                                  check_exit=False).split():
                found.append((window, xdotool("getwindowname", window, check_exit=False).strip()))
            return found

        def window(picker=False):
            for window_id, title in clipboard_windows():
                if title.endswith("Picker") == picker:
                    return window_id
            return None

        def origin(window_id):
            values = dict(line.split("=") for line in xdotool("getwindowgeometry", "--shell", window_id).split())
            return int(values["X"]), int(values["Y"])

        def click(window_id, point):
            x, y = origin(window_id)
            xdotool("mousemove", str(x + point[0]), str(y + point[1]), "click", "1")
            time.sleep(1.2)

        def scroll(window_id, clicks):
            x, y = origin(window_id)
            xdotool("mousemove", str(x + UI_SCROLL_AT[0]), str(y + UI_SCROLL_AT[1]))
            for _ in range(abs(clicks)):
                xdotool("click", "5" if clicks > 0 else "4")
                time.sleep(0.1)
            time.sleep(1)

        def key(*keys):
            for name in keys:
                xdotool("key", "--clearmodifiers", name)
                time.sleep(0.4)

        def copy(data_bytes, target):
            """A user's copy: an X11 selection owner that stays until the next copy replaces it."""
            owner = subprocess.run(["xclip", "-selection", "clipboard", "-i", "-t", target], env=helper_env,
                                   input=data_bytes, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
            check(owner.returncode == 0, f"xclip could not copy {target}")

        def clipboard(target):
            result = subprocess.run(["xclip", "-selection", "clipboard", "-o", "-t", target], env=helper_env,
                                    capture_output=True, timeout=30)
            return result.stdout if result.returncode == 0 else b""

        def pick(term, wanted, target):
            """Opens the quick picker in the running Clipboard, searches for `term` and chooses the match."""
            run(installed, "--overlay", timeout=30)
            # With a window manager the picker is its own window ("... Picker"); without one (Xvfb) the main window
            # shows it. Either way it is the visible Clipboard window.
            picker = wait(lambda: window(picker=True) or window(), f"the picker to open for {term!r}", 20)
            xdotool("windowfocus", picker)
            time.sleep(0.8)
            xdotool("type", "--delay", "60", term)
            time.sleep(1.5)
            key("Return")
            got = wait(lambda: (value if (value := clipboard(target)) and wanted(value) else None),
                       f"the clipboard to carry the clip found by {term!r} ({target})", 15)
            return got

        try:
            # ---- OLD is installed from a download, as a user does it ------------------------------------------
            start_keyring()
            old_version = run(download(old_image), "--version").strip().split()[-1]
            receipt = json.loads(run(downloads / old_image.name, "--install", "--silent", "--no-launch"))
            check(Path(receipt["path"]) == installed, receipt)
            check(receipt["version"] == old_version, receipt)
            check(digest(installed) == digest(old_image), "The installed copy is not OLD's bytes")
            old_login = Path(receipt["integration"]["autostart"])
            check(old_login.is_file() and old_login.parent == autostart_folder and old_login.name == AUTOSTART,
                  f"OLD set up no login entry: {receipt}")
            check(Path(receipt["integration"]["desktopEntry"]) == launcher, receipt["integration"])
            check(not clipboard_processes(root), "--no-launch started Clipboard")

            first = start()
            check(first["version"] == old_version and first["app"] == APP_ID, first)

            # ---- first run: "Start on this device" by keyboard (Tab, Enter; the name, the copy switch, Back, Start)
            run(installed, "--show", timeout=30)
            main_window = wait(lambda: window(), "OLD's window", 30)
            xdotool("windowfocus", main_window)
            time.sleep(1)
            key("Tab", "Return")
            time.sleep(1)
            key("Tab", "Tab", "Tab", "Tab", "Tab", "Return")
            wait(lambda: history.exists() and "mesh_id" in meta_table(read_database(history)),
                 f"OLD to create the mesh (first-run setup by keyboard); window {clipboard_windows()}", 40)

            # ---- what the user copies: text, a link, a file ----------------------------------------------------
            documents = root / "home/Documents"
            documents.mkdir()
            user_file = documents / FILE_NAME
            user_file.write_text(FILE_CONTENT)
            user_files = {user_file: digest(user_file)}

            def stored_kinds():
                try:
                    return sorted(row[0] for row in table_rows(read_database(history), "items", "kind"))
                except sqlite3.Error:
                    return []

            copy(TEXT.encode(), "UTF8_STRING")
            wait(lambda: len(stored_kinds()) >= 1, "OLD to capture the copied text")
            copy(LINK.encode(), "UTF8_STRING")
            wait(lambda: len(stored_kinds()) >= 2, "OLD to capture the copied link")
            copy(f"file://{user_file}\r\n".encode(), "text/uri-list")
            wait(lambda: len(stored_kinds()) >= 3, "OLD to capture the copied file")
            check(stored_kinds() == ["file", "text", "url"], f"OLD stored the copies as {stored_kinds()}")

            # ---- settings, changed in OLD's Settings page ---------------------------------------------------------
            run(installed, "--settings", timeout=30)
            time.sleep(2)
            page = wait(lambda: window(), "the Settings page", 15)
            check(origin(page) is not None, "no window origin")
            scroll(page, 12)
            click(page, UI_KEEP_DROPDOWN)
            click(page, UI_KEEP_7_DAYS)
            wait(lambda: settings_table(read_database(history)).get("retention_hours") == RETENTION_HOURS,
                 f"Keep history to change to 7 days in OLD (retention_hours is "
                 f"{settings_table(read_database(history)).get('retention_hours')!r})", 10)
            click(page, UI_BUDGET_DROPDOWN)
            click(page, UI_BUDGET_1_GB)
            wait(lambda: settings_table(read_database(history)).get("max_storage_mb") == MAX_STORAGE_MB,
                 f"Storage budget to change to 1 GB in OLD (max_storage_mb is "
                 f"{settings_table(read_database(history)).get('max_storage_mb')!r})", 10)
            scroll(page, -12)
            click(page, UI_DARK)
            wait(lambda: settings_json.exists() and json.loads(settings_json.read_text()).get("appearance_mode") == APPEARANCE,
                 f"Appearance to change to Dark in OLD ({settings_json.read_text() if settings_json.exists() else 'no settings.json'})",
                 10)

            # ---- the profile, as OLD leaves it: stop, snapshot, start again ------------------------------------
            stop()
            before_stopped = read_database(history)
            old_secrets = secret_items()
            check(len(old_secrets) == 1, f"Expected one Clipboard history key in the Secret Service, found {sorted(old_secrets)}")
            start()
            time.sleep(3)  # OLD's startup clean-up has run by now
            before = read_database(history)
            old_settings_json = json.loads(settings_json.read_text())
            check(table_rows(before, "items", *ITEM_COLUMNS) == table_rows(before_stopped, "items", *ITEM_COLUMNS),
                  "OLD changed its history when it started again")
            check(len(before["items"][1]) == 3, f"{old_version} holds {len(before['items'][1])} clips, expected 3")
            old_settings = settings_table(before)
            check(old_settings["retention_hours"] == RETENTION_HOURS and old_settings["max_storage_mb"] == MAX_STORAGE_MB,
                  f"{old_version} changed the settings it was given: {old_settings}")
            check(old_settings_json.get("appearance_mode") == APPEARANCE, old_settings_json)
            old_meta = meta_table(before)
            ((old_username, (old_secret_hash, old_secret_attributes)),) = old_secrets.items()
            print(f"{old_version} installed at {installed} and running with the user's data: "
                  f"{len(before['items'][1])} clips (text, link, file), mesh {old_meta['mesh_id']}, "
                  f"settings retention {old_settings['retention_hours']} h, budget {old_settings['max_storage_mb']} MB, "
                  f"appearance {old_settings_json['appearance_mode']}, history key {old_username[:20]}...", flush=True)

            old_pids = set(clipboard_processes(root))
            check(old_pids, "OLD has no process of its own")

            # ---- the update is by hand while OLD runs: download NEW, double click (--install, then start it) -----
            new_download = download(new_image)
            new_version = run(new_download, "--version").strip().split()[-1]
            check(SAME_VERSION or new_version != old_version, f"NEW is {new_version}, the same release as OLD")
            # Like a double click, the update install is not --no-launch: it stops OLD, installs and starts NEW with
            # --background. Output goes to a file, not a pipe: the started Clipboard inherits it.
            with (root / "update.log").open("w+b") as update:
                try:
                    result = subprocess.run([str(new_download), "--install", "--silent"], env=env, stdout=update,
                                            stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=120)
                except subprocess.TimeoutExpired:
                    raise Failure("NEW's --install did not finish in 120s")
                update.seek(0)
                output = update.read().decode(errors="replace")
            check(result.returncode == 0, f"NEW --install exited {result.returncode}: {output[-2000:]}")
            check("{" in output, f"NEW --install printed no receipt: {output[-2000:]}")
            upgraded = json.JSONDecoder().raw_decode(output[output.index("{"):])[0]
            wait(lambda: not any(alive(pid) for pid in old_pids), "OLD to exit during the install", 30)
            check(digest(installed) == digest(new_image), "The installed copy is not NEW's bytes")
            if not SAME_VERSION:
                check(digest(installed) != digest(old_image), "The installed copy is still OLD's bytes")
            check(upgraded["version"] == new_version and Path(upgraded["path"]) == installed, upgraded)
            check(upgraded["installedAt"] == receipt["installedAt"], "The upgrade reset the original install date")
            check(upgraded.get("previous", {}).get("version") == old_version,
                  f"The receipt does not record the replaced {old_version}: {upgraded.get('previous')}")

            try:
                new_resident = wait(lambda: (i if (i := running()) and i.get("runningVersion") == new_version else None),
                                    "NEW to be started by the install", 60)
            except Failure as failure:
                raise Failure(f"{failure}: {new_version} did not come up over {old_version}'s profile (it opens a profile "
                              f"only with the history key it stored; see the log above); the history key is "
                              f"{'there' if secret_items() else 'MISSING'} in the Secret Service, the history database is "
                              f"{'there' if history.exists() else 'MISSING'}")
            check(new_resident["runningVersion"] == new_version, f"--status reports {new_resident}")
            check(not any(alive(pid) for pid in old_pids), "OLD's process is still there")
            time.sleep(3)  # NEW's startup clean-up has run

            # ---- the integration is NEW's: one launcher, at most one login entry, both starting the installed file
            integration = json.loads(run(installed, "--integration-status", timeout=60))
            check(integration["receipt"]["version"] == new_version, integration["receipt"])
            check(Path(integration["receipt"]["path"]) == installed, integration["receipt"])
            missing = [entry["path"] for entry in integration["entries"] if not entry["exists"]]
            check(not missing, f"Integration entries missing after the upgrade: {missing}")
            entries = upgraded["integration"]
            check(Path(entries["desktopEntry"]) == launcher, f"The launcher moved: {entries['desktopEntry']}")

            def mentions_clipboard(path):
                text = path.read_text(errors="replace")
                return f"X-Arcade-Id={APP_ID}" in text or "clipboard" in path.name.lower()

            # Anywhere a launcher or login entry can be in this profile: Link's folders and the XDG ones.
            launchers = sorted({path for folder in (arcade / ".local/share/applications", root / "data/applications",
                                                    root / "home/.local/share/applications")
                                if folder.is_dir() for path in folder.glob("*.desktop") if mentions_clipboard(path)})
            check(launchers == [launcher], f"Expected one Clipboard launcher, found {launchers}")
            check(f'Exec="{installed}"\n' in launcher.read_text(), launcher.read_text())
            logins = sorted({path for folder in (autostart_folder, root / "config/autostart", root / "home/.config/autostart")
                             if folder.is_dir() for path in folder.glob("*.desktop") if mentions_clipboard(path)})
            check(len(logins) <= 1, f"More than one Clipboard login entry: {logins}")
            for login in logins:
                text = login.read_text()
                check(f'Exec="{installed}" "--background"' in text, f"{login} does not start the installed file:\n{text}")
                check("Hidden=true" not in text and "X-GNOME-Autostart-enabled=false" not in text, text)
            check(logins == [old_login], f"The login entry changed: {old_login} -> {logins}")
            cli = Path(entries["cli"])
            check(cli.resolve() == installed, f"{cli} -> {cli.resolve()}")
            for icon in entries["icons"]:
                check(Path(icon).is_file(), f"Icon {icon} is missing")
            # Link keeps the replaced file as `.previous` for a rollback; no other package may sit beside the install.
            beside = sorted(path.name for path in installed.parent.iterdir() if path.name.endswith(".AppImage"))
            check(beside == [FILENAME], f"Other packages beside the installed copy: {beside}")

            def verify_profile():
                """The profile NEW sees (history.sqlite, settings.json, the Secret Service) against OLD's."""
                new_secrets = secret_items()
                check(set(new_secrets) == {old_username},
                      f"The Secret Service holds {sorted(new_secrets)} after the upgrade, was {[old_username]}: NEW made a "
                      f"second identity or lost the first")
                check(new_secrets[old_username][0] == old_secret_hash, "The history key in the Secret Service changed")
                check(new_secrets[old_username][1] == old_secret_attributes, "The history key's attributes changed")
                check(history.exists(), f"{new_version} left no history database (OLD had {len(before['items'][1])} clips)")
                after = read_database(history)
                before_items = table_rows(before, "items", *ITEM_COLUMNS)
                after_items = table_rows(after, "items", *ITEM_COLUMNS)
                for row in before_items:
                    check(row in after_items, f"{new_version}: clip {dict(zip(ITEM_COLUMNS, row))} is gone or changed "
                                              f"(has {len(after_items)} clips)")
                identical = table_rows(before, "items") == [row for row in table_rows(after, "items") if row[0] in
                                                            {r[0] for r in before_items}]
                new_meta = meta_table(after)
                for name in ("mesh_id", "owner_device_id", "owner_signing_public", "owner_static_public", "device_name"):
                    check(new_meta.get(name) == old_meta.get(name),
                          f"meta {name} changed: {old_meta.get(name)!r} -> {new_meta.get(name)!r}")
                # Not the endpoint and last_seen, which follow the listening port and the clock of each start.
                device = ("device_id", "device_name", "static_public", "certificate", "owner", "revoked_at")
                check(table_rows(after, "devices", *device) == table_rows(before, "devices", *device),
                      f"The device records changed: {table_rows(before, 'devices', *device)} -> "
                      f"{table_rows(after, 'devices', *device)}")
                new_settings = settings_table(after)
                check(new_settings.get("retention_hours") == RETENTION_HOURS,
                      f"Keep history is {new_settings.get('retention_hours')!r} hours after the upgrade, was {RETENTION_HOURS}")
                check(new_settings.get("max_storage_mb") == MAX_STORAGE_MB,
                      f"Storage budget is {new_settings.get('max_storage_mb')!r} MB after the upgrade, was {MAX_STORAGE_MB}")
                check(new_settings.get("paused") == old_settings["paused"], f"Private mode changed: {new_settings}")
                new_settings_json = json.loads(settings_json.read_text())
                for name, value in old_settings_json.items():
                    check(new_settings_json.get(name) == value,
                          f"settings.json {name} is {new_settings_json.get(name)!r}, was {value!r}")
                return identical

            # ---- the data, read through NEW -------------------------------------------------------------------
            # The history is encrypted: NEW opens the quick picker, searches for each clip and chooses it, and the
            # clipboard must carry what the user copied. That only works with the history key OLD stored.
            verify_profile()  # NEW's own writes so far, while it runs
            got = pick("kiwi", lambda value: value.decode(errors="replace").strip() == TEXT, "UTF8_STRING")
            check(got.decode().strip() == TEXT, f"NEW pasted {got!r} for the text clip")
            got = pick("pomelo", lambda value: value.decode(errors="replace").strip() == LINK, "UTF8_STRING")
            check(got.decode().strip() == LINK, f"NEW pasted {got!r} for the link clip")

            def a_copy_of_the_file(value):
                paths = [line[7:] for line in value.decode(errors="replace").splitlines() if line.startswith("file://")]
                return len(paths) == 1 and Path(paths[0]).is_file() and Path(paths[0]).read_text() == FILE_CONTENT

            got = pick("papaya", a_copy_of_the_file, "text/uri-list")
            check(a_copy_of_the_file(got), f"NEW pasted {got!r} for the file clip")

            time.sleep(2)
            stop()
            check(not running(), "NEW still runs after --quit")
            check(b"panicked at" not in (root / "clipboard.log").read_bytes(), "Clipboard logged a panic")
            check(b"Secure identity is missing" not in (root / "clipboard.log").read_bytes()
                  and b"credential store" not in (root / "clipboard.log").read_bytes(), "Clipboard logged a key problem")

            identical = verify_profile()  # again, after NEW stopped and wrote its last changes
            for path, value in user_files.items():
                check(digest(path) == value, f"The user's own file {path} was changed")
            print(f"{new_version} replaced {old_version} in place: {len(before["items"][1])} clips read back through the "
                  f"picker (text, link, file), the mesh and device, Keep history {RETENTION_HOURS} h, budget "
                  f"{MAX_STORAGE_MB} MB, Dark appearance and the same history key kept; one launcher, {len(logins)} login entry, "
                  f"both start the installed file; clip ciphertext {'unchanged' if identical else 're-encrypted'}",
                  flush=True)
        except Exception:
            log.seek(0)
            print(log.read().decode(errors="replace")[-6000:], file=sys.stderr)
            raise
        finally:
            if installed.exists():
                try:
                    subprocess.run([str(installed), "--quit"], env=env, capture_output=True, timeout=30)
                    time.sleep(1)
                except (subprocess.TimeoutExpired, OSError):
                    pass
            for pid in clipboard_processes(root):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            for process in [*launched, *keyring]:
                if process.poll() is None:
                    process.kill()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    pass
    print(f"PASS: {old_version} -> {new_version} keeps the user's history, settings, history key and integration")


if __name__ == "__main__":
    try:
        main()
    except Failure as failure:
        print(f"FAIL: {failure}", file=sys.stderr)
        sys.exit(1)
