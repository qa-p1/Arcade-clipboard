#!/usr/bin/env python3
"""Package a bundle built by scripts/dev.sh; no build or publishing happens here."""
import argparse
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--platform', choices=['linux', 'windows', 'macos'], required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9][0-9A-Za-z.+-]*', args.version):
        parser.error('version must be a safe release version')
    out = ROOT / 'dist/packages'
    out.mkdir(parents=True, exist_ok=True)
    if args.platform == 'linux':
        source = ROOT / 'dist/Arcade-Clipboard-linux-x64.tar.gz'
        shutil.copy2(source, out / f'Arcade-Clipboard_{args.version}_linux_x64.tar.gz')
    elif args.platform == 'windows':
        source = ROOT / 'apps/flutter_app/build/windows/x64/runner/Release'
        if not (source / 'clipboard.exe').is_file() or not (source / 'arcade_core.dll').is_file():
            raise SystemExit('Build the Windows app/core with bash scripts/dev.sh build-windows first')
        compiler = shutil.which('ISCC.exe') or str(Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / 'Inno Setup 6/ISCC.exe')
        subprocess.run([compiler, f'/DAppVersion={args.version}', f'/DSourceDir={source}',
                        f'/DOutputDir={out}', str(ROOT / 'packaging/windows/arcade-clipboard.iss')], check=True)
    else:
        source = ROOT / 'apps/flutter_app/build/macos/Build/Products/Release/Arcade Clipboard.app'
        if not (source / 'Contents/Frameworks/libarcade_core.dylib').is_file():
            raise SystemExit('Build the macOS app/core with bash scripts/dev.sh build-macos first')
        stage = ROOT / 'dist/dmg'
        if stage.exists():
            shutil.rmtree(stage)
        stage.mkdir()
        shutil.copytree(source, stage / source.name, symlinks=True)
        (stage / 'INSTALL.txt').write_text('Copy Arcade Clipboard.app to ~/Applications.\nOpen it yourself; this build is not notarized.\n')
        arch = 'arm64' if platform.machine().lower() in ('arm64', 'aarch64') else 'x64'
        subprocess.run(['hdiutil', 'create', '-volname', 'Arcade Clipboard', '-srcfolder', str(stage),
                        '-ov', '-format', 'UDZO', str(out / f'Arcade-Clipboard_{args.version}_macos_{arch}.dmg')], check=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
