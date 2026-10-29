#!/usr/bin/env python3
"""Check links, shortcuts, screenshots and the pinned Arcade Link assets."""
import hashlib
import json
from pathlib import Path
import re
import os
import subprocess
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent

def anchors(path):
    seen = {}
    result = set()
    for heading in re.findall(r"^#{1,6}\s+(.+)$", path.read_text(encoding="utf-8"), re.M):
        slug = re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
        n = seen.get(slug, 0)
        seen[slug] = n + 1
        result.add(slug if n == 0 else f"{slug}-{n}")
    return result

def main():
    errors = []
    checked = 0
    files = [ROOT / "README.md", ROOT / "CHANGELOG.md", *sorted((ROOT / "docs").rglob("*.md"))]
    for file in files:
        for target in re.findall(r"\[[^\]]*\]\(([^)]+)\)", file.read_text(encoding="utf-8")):
            target = target.strip().split(' "', 1)[0].strip("<>")
            url = urlsplit(target)
            if url.scheme or url.netloc:
                continue  # External URLs are not fetched by this offline check.
            path = (file.parent / unquote(url.path)).resolve() if url.path else file
            checked += 1
            # Tools shows the user guide offline: it may link only inside
            # docs/user/ or to absolute URLs (STANDARD §10).
            user = (ROOT / "docs/user").resolve()
            if file.resolve().is_relative_to(user) and not path.is_relative_to(user):
                errors.append(f"{file.relative_to(ROOT)}: {target} leaves docs/user/; use an absolute URL")
            if not path.exists():
                errors.append(f"{file.relative_to(ROOT)}: missing {target}")
            elif url.fragment and path.suffix == ".md" and unquote(url.fragment) not in anchors(path):
                errors.append(f"{file.relative_to(ROOT)}: missing fragment {target}")
    source = ROOT / "docs/user/shortcuts.json"
    doc = json.loads(source.read_text(encoding="utf-8"))
    version = re.search(r'^version = "([^"]+)"', (ROOT / "Cargo.toml").read_text(encoding="utf-8"), re.M).group(1)
    if doc["app"] != "arcade.clipboard" or doc["version"] != version:
        errors.append("shortcuts app/version differs from the build")
    generated = subprocess.check_output([sys.executable, str(ROOT / "tools/validate_shortcuts.py"), str(source), "--markdown"],
                                        encoding="utf-8", env={**os.environ, "PYTHONUTF8": "1"})
    if generated != (ROOT / "docs/user/shortcuts.md").read_text(encoding="utf-8"):
        errors.append("shortcuts.md is stale; regenerate it with tools/validate_shortcuts.py")
    images = list((ROOT / "docs/user/images").glob("*.png"))
    if not images:
        errors.append("docs/user/images needs a PNG screenshot")
    for image in images:
        if image.stat().st_size > 300_000:
            errors.append(f"{image.relative_to(ROOT)}: exceeds the 300 KB screenshot budget")
        if not image.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
            errors.append(f"{image.relative_to(ROOT)}: not a PNG")
    inventory = (ROOT / "scripts/VENDORED").read_text(encoding="utf-8")
    assets = re.findall(r"^  (\S+) SHA-256 ([0-9a-f]{64})$", inventory, re.M)
    release_hash = re.search(r"^SHA-256: ([0-9a-f]{64})\.$", inventory, re.M).group(1)
    assets.append(("scripts/arcade-release.py", release_hash))
    for name, expected in assets:
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
            errors.append(f"{name}: vendored checksum differs from scripts/VENDORED")
    if errors:
        sys.exit("\n".join(errors))
    print(f"docs: {checked} local links, shortcuts, screenshots and {len(assets)} vendored checksums passed")

if __name__ == "__main__":
    main()
