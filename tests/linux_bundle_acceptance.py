#!/usr/bin/env python3
"""Verify the normal Linux release in the isolated Arcade e2e session.

Run through tools/e2e.py run -- python3 tests/linux_bundle_acceptance.py.
Every copied value is synthetic; this never builds or touches a live desktop.
"""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
LINK = ROOT.parents[1] / "Rust/Arcade-link"


def load(path, name, **globals):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    module.__dict__.update(globals)
    spec.loader.exec_module(module)
    return module


def main():
    if os.environ.get("ARCADE_E2E_INNER") != "1" or os.environ.get("WAYLAND_DISPLAY"):
        raise SystemExit("Use the isolated Arcade e2e runner for this GUI check")
    runner = load(LINK / "tools/e2e.py", "arcade_runner")
    checks = load(LINK / "tools/e2e_checks/clipboard.py", "clipboard_checks",
                  check=lambda _: lambda f: f, APPS=runner.APPS, CLI=runner.CLI)
    # The outer runner already owns Xvfb, D-Bus and the keyring. Reuse that
    # private environment, tracking only the application PIDs we start here.
    s = object.__new__(runner.Session)
    s.root = Path(os.environ["ARCADE_E2E_ROOT"])
    s.env = dict(os.environ)
    s.procs = {}
    app = runner.APPS["arcade.clipboard"]
    app["args"] = []
    binary = app["dir"] / app["bin"]
    try:
        for variant in ("alone", "all-peers"):
            s.env["ARCADE_DATA_DIR"] = str(s.root / f"acceptance-{variant}")
            checks._driver(s, checks._initialize(s),
                           {"op": "create_mesh", "device_name": "Clipboard acceptance"},
                           {"op": "shutdown"})
            if variant == "alone":
                rows = json.loads(s.cli("ls", "--json", check=True).stdout)
                assert all(r["id"] == "arcade.clipboard" for r in rows), rows
            else:
                s.env["ALOOK_E2E_MAP_EARLY"] = "1"
                for peer in ("arcade.box", "arcade.lens", "arcade.look", "arcade.wheel"):
                    s.start(peer)
            process = s.start("arcade.clipboard")
            window = s.wait_window("Arcade Clipboard")
            s.xdotool("windowsize", "--sync", window, "1180", "820")
            s.xdotool("windowfocus", "--sync", window)
            checks._ui_wait(s, window, "Your clipboard is empty")
            s.screenshot(f"clipboard-{variant}-launch", window)

            sample = f"Synthetic clipboard text ({variant})"
            checks._publish_clipboard(s, "text", sample)
            checks._ui_wait(s, window, "Synthetic clipboard text")
            checks._ui_wait(s, window, "1 clip")
            s.screenshot(f"clipboard-{variant}-text-capture", window)

            image = s.root / f"acceptance-{variant}.png"
            subprocess.run(["magick", "-size", "720x220", "xc:white", "-fill", "#146B58",
                            "-font", "DejaVu-Sans", "-pointsize", "48", "-gravity", "center",
                            "-annotate", "0", "Synthetic image copy", str(image)],
                           env=s.env, capture_output=True, check=True, timeout=15)
            checks._publish_clipboard(s, "image", image)
            checks._ui_wait(s, window, "Image")
            checks._ui_wait(s, window, "2 clips")
            s.screenshot(f"clipboard-{variant}-image-capture", window)

            # Exercise the default global shortcut, including native binding.
            s.xdotool("key", "ctrl+shift+space")
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                words = checks._ui_words(s, window)
                if any(y < 80 for _, y in checks._ui_matches(words, "Mesh Clipboard")):
                    break
                time.sleep(0.1)
            else:
                raise AssertionError("Global shortcut did not open the actual picker title")
            checks._ui_wait(s, window, "Synthetic clipboard text")
            s.screenshot(f"clipboard-{variant}-picker", window)
            s.xdotool("key", "Escape")
            s.cli("activate", "clipboard", check=True)
            s.wait_window("Arcade Clipboard")
            started = time.monotonic()
            quit = subprocess.run([str(binary), "--quit"], env=s.env,
                                  capture_output=True, text=True, timeout=10)
            assert quit.returncode == 0, quit.stderr
            process.wait(timeout=5)
            quit_seconds = time.monotonic() - started
            assert process.returncode == 0, s.log("arcade.clipboard")
            assert not s.endpoint("arcade.clipboard").exists()
            assert not s.xdotool("search", "--onlyvisible", "--name", "Arcade Clipboard")
            s.procs.pop("arcade.clipboard")
            s.kill("clipboard-owner")
            s.screenshot(f"clipboard-{variant}-quit")
            history = checks._driver(s, checks._initialize(s), {"op": "history"}, {"op": "shutdown"})[1]
            rows = history if isinstance(history, list) else history["items"]
            assert len(rows) == 2 and {r["kind"] for r in rows} == {"text", "image"}, rows
            assert next(r["text"] for r in rows if r["kind"] == "text") == sample, rows
            print(f"PASS {variant}: native text/image copies, history, default picker shortcut, --quit "
                  f"({quit_seconds:.2f}s), persisted text/image clips", flush=True)
            for peer in list(s.procs):
                s.kill(peer, signal.SIGTERM)
    finally:
        for peer in list(s.procs):
            s.kill(peer, signal.SIGTERM)


if __name__ == "__main__":
    main()
