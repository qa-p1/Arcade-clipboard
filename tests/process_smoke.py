#!/usr/bin/env python3
"""Exercise the real app API in two processes using synthetic text only.

Requires a working, unlocked OS Secret Service on Linux. No test key-storage
fallback is injected: this checks the same storage boundary used by the app.
"""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time


class Client:
    def __init__(self, binary, directory, name):
        self.process = subprocess.Popen(
            [str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        self.call("initialize", data_dir=str(directory), device_name=name)

    def call(self, operation, **arguments):
        self.process.stdin.write(json.dumps({"op": operation, **arguments}) + "\n")
        self.process.stdin.flush()
        readable, _, _ = select.select([self.process.stdout], [], [], 25)
        if not readable:
            raise AssertionError(f"Timed out waiting for {operation}")
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError(f"Driver exited during {operation}")
        response = json.loads(line)
        if "error" in response:
            raise AssertionError(f"{operation}: {response['error']}")
        return response["ok"]

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()


def eventually(predicate, label, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(f"Timed out: {label}")


def rows(client):
    result = client.call("history", query="", limit=100)
    return result.get("items", [])


def run(binary, directory):
    clients = []
    try:
        a = Client(binary, directory / "A", "Test desktop A")
        clients.append(a)
        b = Client(binary, directory / "B", "Test desktop B")
        clients.append(b)
        a.call("create_mesh", device_name="Test desktop A")
        invite = a.call("create_invite")["invite"]
        b.call("join", invite=invite, device_name="Test desktop B")
        pending_a = eventually(lambda: a.call("status").get("pending_pairings"), "A pairing")
        pending_b = eventually(lambda: b.call("status").get("pending_pairings"), "B pairing")
        assert pending_a[0]["verification_code"] == pending_b[0]["verification_code"], "SAS mismatch"
        a.call("confirm_pairing", session_id=pending_a[0]["session_id"], accept=True)
        b.call("confirm_pairing", session_id=pending_b[0]["session_id"], accept=True)
        eventually(lambda: b.call("status").get("mesh_id"), "trusted mesh")
        sa, sb = a.call("status"), b.call("status")
        assert sa["device_id"] != sb["device_id"], "Isolated clients reused one identity"
        assert sa["mesh_id"] == sb["mesh_id"]
        sample = "  Arcade ✓ हिन्दी\nsecond line\t  "
        a.call("capture", text=sample)
        received = eventually(lambda: [r for r in rows(b) if r["text"] == sample], "encrypted text sync")
        assert len(received) == 1
        assert received[0]["origin_device"] == sa["device_id"]
        assert len([r for r in rows(a) if r["text"] == sample]) == 1
        print("PASS: distinct secure identities, human-confirmed pairing, encrypted text sync, provenance")

        b.close()
        clients.remove(b)
        offline_sample = "Synthetic offline catch-up sample"
        a.call("capture", text=offline_sample)
        b = Client(binary, directory / "B", "Test desktop B")
        clients.append(b)
        eventually(lambda: [r for r in rows(b) if r["text"] == offline_sample], "restart catch-up")
        assert len([r for r in rows(b) if r["text"] == sample]) == 1
        print("PASS: secure restart, retained trust, offline catch-up without duplication")

        a.call("settings", values={"paused": True})
        # A paused capture may return a typed rejection or a non-stored result.
        try:
            a.call("capture", text="MUST NOT BE STORED")
        except AssertionError as error:
            if "paused" not in str(error).lower():
                raise
        assert not any(r["text"] == "MUST NOT BE STORED" for r in rows(a))
        print("PASS: capture pause enforced in core")
    finally:
        for client in clients:
            client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=Path("target/debug/arcade_test_driver"))
    parser.add_argument("--data-dir", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    if args.data_dir:
        args.data_dir.mkdir(parents=True, exist_ok=True)
        run(binary, args.data_dir.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="arcade-process-test-") as temporary:
            run(binary, Path(temporary))
