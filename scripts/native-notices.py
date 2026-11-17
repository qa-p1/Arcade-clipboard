#!/usr/bin/env python3
"""Record the Ubuntu packages whose files the Linux AppImage bundles, for THIRD_PARTY_NOTICES.md.

  scripts/native-notices.py Arcade-Clipboard-1.0.0-x86_64.AppImage           # rewrite packaging/linux/native/
  scripts/native-notices.py --check Arcade-Clipboard-1.0.0-x86_64.AppImage   # fail if the record or the image is wrong

Runs on the build host (Ubuntu 22.04 in CI, the oldest supported), where scripts/dev build-linux copied the one system library the bundle
carries (libkeybinder) from. Every ELF file in the image is mapped to the Debian package that installed it
(`dpkg -S`); each package's `copyright` file is kept under packaging/linux/native/copyright/, and packages.json
names its source package. Versions are not recorded, so an Ubuntu security update does not change the result. An
executable or library that maps to no package and is not Clipboard's, a Flutter plugin's or the Flutter engine's
(OWN) fails the run, so a new bundled library is noticed.

--check also fails when the image lacks `data/flutter_assets/NOTICES.Z` (Flutter's compiled third-party licences, shown
in Settings > Licences), when its `data/licenses/THIRD_PARTY_NOTICES.md` differs from the repository's, or when the
AppImage runtime lists a component that scripts/notices.py does not (the runtime prints its own licence block).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / "packaging" / "linux" / "native"
BUNDLE = "usr/lib/arcade-clipboard"
OWN = tuple(f"{BUNDLE}/{name}" for name in (
    # This repository's runner, its launcher and the Wayland capture helper.
    "clipboard", "arcade-clipboard-launcher", "lib/arcade_clipboard_wl_capture",
    # The Rust core and the native part of arcade_desktop_bridge.
    "lib/libarcade_core.so", "lib/libarcade_desktop_bridge_plugin.so",
    # The Dart program (AOT snapshot) and the Flutter engine.
    "lib/libapp.so", "lib/libflutter_linux_gtk.so",
    # Flutter plugins built from pub packages (and the vendored hotkey_manager_linux), and jni's helper library.
    "lib/libfile_selector_linux_plugin.so", "lib/libhotkey_manager_linux_plugin.so",
    "lib/libscreen_retriever_linux_plugin.so", "lib/libwindow_manager_plugin.so", "lib/libdartjni.so",
))
# What the AppImage runtime says it contains (its `License:` block); scripts/notices.py lists each.
RUNTIME_COMPONENTS = ("runtime", "musl libc", "libfuse", "squashfuse", "libzstd", "zlib")
LIB_DIRS = ("/usr/lib/x86_64-linux-gnu", "/lib/x86_64-linux-gnu", "/usr/lib", "/lib")


def is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def candidates(relative):
    """Host paths a bundled file may have come from: the same path, or the same name in a system library folder."""
    out = ["/" + relative, *(f"{d}/{Path(relative).name}" for d in LIB_DIRS)]
    seen, paths = set(), []
    for p in out:
        for q in (p, os.path.realpath(p)):
            if q not in seen and os.path.lexists(q):
                seen.add(q)
                paths.append(q)
    return paths


def owners(paths):
    """dpkg -S for many paths at once: {path: package}."""
    found = {}
    for i in range(0, len(paths), 200):
        batch = paths[i:i + 200]
        run = subprocess.run(["dpkg-query", "-S", *batch], capture_output=True, text=True)
        for line in run.stdout.splitlines():
            names, _, path = line.partition(": ")
            if path in batch and "diversion" not in names:
                found[path] = names.split(",")[0].strip()
    return found


def package_info(package):
    bare = package.split(":")[0]
    source = subprocess.run(["dpkg-query", "-W", "-f", "${source:Package}", package],
                            check=True, capture_output=True, text=True).stdout.strip() or bare
    copyright_file = Path("/usr/share/doc") / bare / "copyright"
    if not copyright_file.is_file():
        sys.exit(f"native-notices: {package} has no {copyright_file}")
    return bare, source, copyright_file.read_text(encoding="utf-8", errors="replace")


def runtime_components(image):
    """The component names in the licence block the AppImage runtime prints (it sits at the start of the file)."""
    head = image.read_bytes()[:4 * 1024 * 1024]
    block = re.search(rb"This executable contains code from\n(.*?)\nPlease see", head, re.S)
    if not block:
        sys.exit("native-notices: the AppImage runtime has no licence block; update RUNTIME_COMPONENTS and notices.py")
    return tuple(re.findall(r"^  \* (.+?), licensed under", block.group(1).decode("utf-8", "replace"), re.M))


def scan(appimage, check):
    with tempfile.TemporaryDirectory() as work:
        image = Path(work) / "image.AppImage"
        shutil.copy2(appimage, image)
        image.chmod(0o755)
        problems = []
        if check:
            found = runtime_components(image)
            if found != RUNTIME_COMPONENTS:
                problems.append(f"the AppImage runtime lists {found}, scripts/notices.py lists {RUNTIME_COMPONENTS}")
        subprocess.run([str(image), "--appimage-extract"], cwd=work, check=True, stdout=subprocess.DEVNULL,
                       env=dict(os.environ, APPIMAGE_EXTRACT_AND_RUN=""))
        root = Path(work) / "squashfs-root"
        files = {}
        for path in root.rglob("*"):
            if path.is_file() and not path.is_symlink():
                files[path.relative_to(root).as_posix()] = is_elf(path)
        if check:
            notices = root / BUNDLE / "data" / "flutter_assets" / "NOTICES.Z"
            if not notices.is_file() or notices.stat().st_size < 10_000:
                problems.append(f"{BUNDLE}/data/flutter_assets/NOTICES.Z (Flutter's compiled licences) is missing or tiny")
            shipped = root / BUNDLE / "data" / "licenses" / "THIRD_PARTY_NOTICES.md"
            repo = ROOT / "THIRD_PARTY_NOTICES.md"
            if not shipped.is_file() or not repo.is_file() or shipped.read_bytes() != repo.read_bytes():
                problems.append(f"{BUNDLE}/data/licenses/THIRD_PARTY_NOTICES.md is missing or differs from the repository's")
        wanted = {rel: candidates(rel) for rel in files}
        mapped = owners(sorted({p for paths in wanted.values() for p in paths}))
        packages, unowned = set(), []
        for rel, elf in sorted(files.items()):
            owner = next((mapped[p] for p in wanted[rel] if p in mapped), None)
            if rel in OWN:
                continue
            if owner:
                packages.add(owner)
            elif elf:
                unowned.append(rel)
        missing = [rel for rel in OWN if rel not in files]
        if missing:
            problems.append("OWN lists files the image does not contain (update scripts/native-notices.py): " + ", ".join(missing))
        if unowned:
            problems.append("bundled programs or libraries from no package:\n  " + "\n  ".join(unowned))
        if problems:
            sys.exit("native-notices: " + "\n".join(problems))
        return packages


def write(packages, into):
    (into / "copyright").mkdir(parents=True, exist_ok=True)
    record = {}
    for package in sorted(packages):
        bare, source, text = package_info(package)
        record[bare] = {"source": source}
        (into / "copyright" / f"{bare}.txt").write_text(text, encoding="utf-8")
    (into / "packages.json").write_text(json.dumps({"host": host(), "packages": record}, indent=2) + "\n",
                                        encoding="utf-8")


def host():
    """The build host's distribution, e.g. "Ubuntu 22.04": the record is only valid for the host it came from."""
    fields = dict(line.split("=", 1) for line in Path("/etc/os-release").read_text().splitlines() if "=" in line)
    return f"{fields.get('NAME', '').strip(chr(34))} {fields.get('VERSION_ID', '').strip(chr(34))}".strip()


def snapshot(folder):
    if not folder.is_dir():
        return {}
    return {p.relative_to(folder).as_posix(): p.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
            for p in sorted(folder.rglob("*")) if p.is_file()}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("appimage", type=Path)
    ap.add_argument("--check", action="store_true", help="fail when packaging/linux/native/ or the image is out of date")
    args = ap.parse_args()
    packages = scan(args.appimage.resolve(), args.check)
    if not args.check:
        shutil.rmtree(NATIVE, ignore_errors=True)
        write(packages, NATIVE)
        print(f"Recorded {len(packages)} bundled packages in {NATIVE.relative_to(ROOT)}; now run scripts/notices.py")
        return
    with tempfile.TemporaryDirectory() as fresh:
        write(packages, Path(fresh))
        now, committed = snapshot(Path(fresh)), snapshot(NATIVE)
        if now != committed:
            added = sorted(set(now) - set(committed))
            removed = sorted(set(committed) - set(now))
            changed = sorted(k for k in set(now) & set(committed) if now[k] != committed[k])
            shutil.rmtree(NATIVE, ignore_errors=True)
            shutil.copytree(fresh, NATIVE)
            sys.exit("packaging/linux/native/ is out of date (the regenerated copy is in the tree):\n"
                     f"  added {added}\n  removed {removed}\n  changed {changed}\n"
                     "Run scripts/native-notices.py on the AppImage, then scripts/notices.py, and commit.")
    print(f"packaging/linux/native/ is current: {len(packages)} bundled packages; Flutter's NOTICES.Z and "
          "THIRD_PARTY_NOTICES.md are in the image")


if __name__ == "__main__":
    main()
