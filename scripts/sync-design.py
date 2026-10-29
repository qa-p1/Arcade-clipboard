#!/usr/bin/env python3
"""Copy the Arcade design kit from an Arcade Link checkout at the pinned tag.

    python3 scripts/sync-design.py --link ../Arcade-Link   # an existing checkout
    python3 scripts/sync-design.py                         # clones the tag

The tag is the one Cargo.toml pins arcade-link to, and the checkout's HEAD must
be that tag's commit. The kit's Dart files land in apps/flutter_app/lib/design/,
Inter in apps/flutter_app/assets/fonts/, the app glyphs and tokens in
apps/flutter_app/assets/arcade/, and Clipboard's icon set in every platform
folder (macOS, Windows, Linux, Android, iOS) plus the README logo. Their hashes
go into the "Arcade design kit" section of scripts/VENDORED, which
scripts/check-docs.py checks.

It then renders the tray icons into apps/flutter_app/assets/arcade/tray/ from
Clipboard's glyph with rsvg-convert: the glyph, monochrome (STANDARD §8). White
and black PNGs (Linux panels, the macOS template image) and .ico files (the
Windows taskbar, per theme). These are generated, so they are not hashed.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LINK_URL = "https://github.com/qa-p1/Arcade-Link"
HEADER = "Arcade design kit"
APP = "apps/flutter_app/"
ICONS = "design/app-icons/clipboard/"
IOS = APP + "ios/Runner/Assets.xcassets/AppIcon.appiconset/"
MACOS = APP + "macos/Runner/Assets.xcassets/AppIcon.appiconset/"
# (source in Link, destination here); a trailing slash copies the folder's files.
FILES = [
    ("design/dart/", APP + "lib/design/"),
    ("design/fonts/InterVariable.ttf", APP + "assets/fonts/InterVariable.ttf"),
    ("design/fonts/OFL.txt", APP + "assets/fonts/OFL.txt"),
    ("design/glyphs/", APP + "assets/arcade/"),
    ("design/tokens.json", APP + "assets/arcade/tokens.json"),
    (ICONS + "icon.svg", "packaging/linux/dev.arcade.Clipboard.svg"),
    (ICONS + "clipboard.ico", APP + "windows/runner/resources/app_icon.ico"),
    (ICONS + "png/256.png", "assets/logo.png"),
    *[(f"{ICONS}android/mipmap-{d}/", f"{APP}android/app/src/main/res/mipmap-{d}/")
      for d in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")],
    *[(f"{ICONS}macos/icon_{n}.png", f"{MACOS}app_icon_{n}.png") for n in (16, 32, 64, 128, 256, 512, 1024)],
    # Flutter's iOS names, by point size and scale.
    *[(f"{ICONS}ios/AppIcon-{px}.png", f"{IOS}Icon-App-{name}.png") for px, name in (
        (20, "20x20@1x"), (40, "20x20@2x"), (60, "20x20@3x"),
        (29, "29x29@1x"), (58, "29x29@2x"), (87, "29x29@3x"),
        (40, "40x40@1x"), (80, "40x40@2x"), (120, "40x40@3x"),
        (120, "60x60@2x"), (180, "60x60@3x"),
        (76, "76x76@1x"), (152, "76x76@2x"), (167, "83.5x83.5@2x"),
        (1024, "1024x1024@1x"))],
]
TRAY = APP + "assets/arcade/tray/"


def pinned_tag() -> str:
    match = re.search(r'arcade-link = \{[^}]*tag = "([^"]+)"', (ROOT / "Cargo.toml").read_text())
    if not match:
        raise SystemExit("Cargo.toml doesn't pin arcade-link to a tag")
    return match.group(1)


def git(link: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(link), *args], check=True, capture_output=True, text=True).stdout.strip()


def pairs(link: Path) -> list[tuple[Path, str]]:
    out = []
    for source, target in FILES:
        if source.endswith("/"):
            files = sorted(p for p in (link / source).iterdir() if p.is_file())
            if not files:
                raise SystemExit(f"{source} is empty in the Link checkout")
            out += [(p, f"{target}{p.name}") for p in files]
        else:
            out.append((link / source, target))
    return out


def sync(link: Path, tag: str) -> None:
    commit = git(link, "rev-parse", "HEAD")
    tagged = git(link, "rev-parse", f"{tag}^{{commit}}")
    if commit != tagged:
        raise SystemExit(f"{link} is at {commit[:12]}, not {tag} ({tagged[:12]})")
    lines = []
    for path, target in pairs(link):
        destination = ROOT / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        digest = hashlib.sha256(destination.read_bytes()).hexdigest()
        lines.append(f"  {target} SHA-256 {digest}")
    section = "\n".join([
        f"{HEADER} files are copied unchanged from Arcade Link tag {tag} (commit",
        f"{commit}) by scripts/sync-design.py; never edit them here.",
        "License: MIT OR Apache-2.0; Inter is under the SIL Open Font License 1.1.",
        *lines,
    ])
    vendored = ROOT / "scripts/VENDORED"
    text = vendored.read_text()
    start = text.find(f"{HEADER} files are copied")
    if start >= 0:
        end = start
        rest = text[start:].splitlines(keepends=True)
        for index, line in enumerate(rest):
            if index > 2 and not line.startswith("  "):
                break
            end += len(line)
        text = text[:start] + section + "\n" + text[end:]
    else:
        text = text.rstrip("\n") + "\n\n" + section + "\n"
    vendored.write_text(text)
    print(f"Synced {len(lines)} design kit files from Link {tag} ({commit[:12]})")
    render_tray_icons()


def render(svg: str, size: int) -> bytes:
    return subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size)], input=svg.encode(),
                          check=True, capture_output=True).stdout


def ico(images: list[tuple[int, bytes]]) -> bytes:
    """An .ico of PNG frames (Windows Vista and later read these)."""
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries, data = b"", b""
    for size, png in images:
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(png), offset + len(data))
        data += png
    return header + entries + data


def render_tray_icons() -> None:
    glyph = (ROOT / APP / "assets/arcade/arcade.clipboard.svg").read_text()
    out = ROOT / TRAY
    out.mkdir(parents=True, exist_ok=True)
    for name, colour in (("white", "#ffffff"), ("black", "#000000")):
        svg = glyph.replace("currentColor", colour)
        (out / f"tray-{name}.png").write_bytes(render(svg, 64))
        (out / f"tray-{name}.ico").write_bytes(ico([(size, render(svg, size)) for size in (16, 20, 24, 32, 48)]))
    print("Rendered the tray icons")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--link", type=Path, help="an Arcade Link checkout at the pinned tag")
    args = parser.parse_args(argv)
    tag = pinned_tag()
    if args.link:
        sync(args.link.resolve(), tag)
        return 0
    with tempfile.TemporaryDirectory() as temp:
        checkout = Path(temp) / "Arcade-Link"
        subprocess.run(["git", "clone", "--quiet", "--depth", "1", "--branch", tag, LINK_URL, str(checkout)], check=True)
        sync(checkout, tag)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
