#!/usr/bin/env python3
"""Build the same Rust core for Android and bundle it in the Flutter runner."""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
TARGETS = {
    "arm64-v8a": ("aarch64-linux-android", "aarch64-linux-android"),
    "x86_64": ("x86_64-linux-android", "x86_64-linux-android"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--abis", default="arm64-v8a,x86_64")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()
    sdk = Path(os.environ.get("ANDROID_HOME", os.environ.get("ANDROID_SDK_ROOT", str(Path.home() / "Android/Sdk"))))
    ndk = os.environ.get("ANDROID_NDK_HOME")
    if not ndk:
        installed = list((sdk / "ndk").glob("*"))
        if not installed:
            raise SystemExit("Install Android NDK 28 or newer, or set ANDROID_NDK_HOME.")
        ndk = max(installed, key=lambda p: tuple(int(v) for v in p.name.split(".")))
    host = {"Linux": "linux-x86_64", "Darwin": "darwin-x86_64", "Windows": "windows-x86_64"}[platform.system()]
    tools = Path(ndk) / "toolchains/llvm/prebuilt" / host / "bin"
    env = os.environ.copy()
    # A repo-local rustup installation is optional; keep it process-scoped.
    local_rustup = ROOT / ".tools/rustup/toolchains"
    rustc_candidates = sorted(local_rustup.glob("*/bin/rustc"))
    if "RUSTC" not in env and rustc_candidates:
        env["RUSTC"] = str(rustc_candidates[-1])
    for abi in args.abis.split(","):
        if abi not in TARGETS:
            raise SystemExit(f"Supported ABIs: {', '.join(TARGETS)}")
        target, prefix = TARGETS[abi]
        compiler = tools / f"{prefix}26-clang{'.cmd' if platform.system() == 'Windows' else ''}"
        if not compiler.exists():
            raise SystemExit(f"Android compiler is missing: {compiler}")
        env[f"CARGO_TARGET_{target.upper().replace('-', '_')}_LINKER"] = str(compiler)
        env[f"CC_{target.replace('-', '_')}"] = str(compiler)
        env[f"AR_{target.replace('-', '_')}"] = str(tools / ("llvm-ar.exe" if platform.system() == "Windows" else "llvm-ar"))
        command = ["cargo", "build", "--locked", "-p", "arcade_core", "--target", target]
        if not args.debug:
            command.append("--release")
        subprocess.run(command, cwd=ROOT, env=env, check=True)
        mode = "debug" if args.debug else "release"
        destination = ROOT / "apps/flutter_app/android/app/src/main/jniLibs" / abi
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "target" / target / mode / "libarcade_core.so", destination)
        print(f"Bundled Rust core for {abi}.")


if __name__ == "__main__":
    main()
