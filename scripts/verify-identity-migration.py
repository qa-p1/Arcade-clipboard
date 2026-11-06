#!/usr/bin/env python3
"""Check migrated identity recovery with a private, disposable Secret Service."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TEST = "secret::tests::migrated_profile_recovers_from_real_secret_service"


def worker(binary):
    daemon = subprocess.Popen(
        ["gnome-keyring-daemon", "--foreground", "--components=secrets", "--unlock"],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    try:
        daemon.stdin.write(b"\n")
        daemon.stdin.close()
        subprocess.run(["gdbus", "wait", "--session", "--timeout=10", "org.freedesktop.secrets"],
                       check=True, timeout=15)
        subprocess.run([binary, TEST, "--exact", "--ignored"], check=True, timeout=45)
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon.kill()
            daemon.wait(timeout=5)
        daemon.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--debug", action="store_true", help="reuse the source-check build")
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        worker(args.worker)
        return
    build = subprocess.run(
        ["cargo", "test", *([] if args.debug else ["--release"]), "--locked", "-p", "arcade_core", "--lib",
         "--no-run", "--message-format=json"], cwd=ROOT, stdout=subprocess.PIPE, text=True,
        check=True,
    )
    binaries = [item["executable"] for line in build.stdout.splitlines()
                if (item := json.loads(line)).get("reason") == "compiler-artifact"
                and item.get("executable") and item["target"]["name"] == "arcade_core"]
    assert len(binaries) == 1, "could not identify the core test executable"
    with tempfile.TemporaryDirectory(prefix="arcade-identity-migration-") as directory:
        root = Path(directory)
        env = {key: value for key, value in os.environ.items()
               if key not in {"DBUS_SESSION_BUS_ADDRESS", "LD_LIBRARY_PATH", "APPDIR", "APPIMAGE"}}
        for name, relative in {"HOME": "home", "XDG_DATA_HOME": "data", "XDG_CONFIG_HOME": "config",
                               "XDG_CACHE_HOME": "cache", "XDG_RUNTIME_DIR": "run"}.items():
            path = root / relative
            path.mkdir(mode=0o700)
            env[name] = str(path)
        env["ARCADE_TEST_IDENTITY_MIGRATION"] = "1"
        subprocess.run(["dbus-run-session", "--", sys.executable, str(Path(__file__).resolve()),
                        "--worker", binaries[0]], env=env, check=True, timeout=90)
    print("PASS: real Secret Service credential survives the standard folder move, mesh and history reopen")


if __name__ == "__main__":
    main()
