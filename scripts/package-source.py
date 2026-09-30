#!/usr/bin/env python3
"""Package source only; never include SDKs, credentials, databases or build trees."""
from pathlib import Path
import os
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
output = root.parent / "Arcade-Clipboard-source.zip"
excluded = {".git", ".tools", "target", "build", ".dart_tool", "__pycache__", ".pytest_cache"}
bundle = root / ".tools" / "source-history.bundle"
if (root / ".git").is_dir():
    bundle.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "bundle", "create", str(bundle), "--all"], cwd=root, check=True)

with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for directory, directories, files in os.walk(root):
        directories[:] = sorted(d for d in directories if d not in excluded)
        for name in sorted(files):
            path = Path(directory) / name
            relative = path.relative_to(root)
            if path.is_symlink() or path.suffix in {".db", ".sqlite", ".pyc"} or name.endswith(("-wal", "-shm")):
                continue
            archive.write(path, Path("arcade-clipboard") / relative)
    if bundle.is_file():
        archive.write(bundle, "Arcade-Clipboard-history.bundle")
print(output)
