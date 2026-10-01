#!/usr/bin/env python3
"""Validate a real iPhone app and its extensions, then package without signing."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


def validate_bundle(bundle, expected_id=None, expected_version=None):
    with (bundle / 'Info.plist').open('rb') as file:
        info = plistlib.load(file)
    required = ['CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleVersion',
                'CFBundleShortVersionString', 'CFBundlePackageType']
    if any(not isinstance(info.get(key), str) or not info[key] or '$(' in info[key]
           for key in required):
        raise ValueError(f'{bundle.name} has missing/unexpanded bundle metadata')
    if expected_id and info['CFBundleIdentifier'] != expected_id:
        raise ValueError(f'{bundle.name} has an unexpected bundle identifier')
    version = (info['CFBundleShortVersionString'], info['CFBundleVersion'])
    if expected_version and version != expected_version:
        raise ValueError(f'{bundle.name} version does not match its app')
    executable = bundle / info['CFBundleExecutable']
    if not executable.is_file() or executable.stat().st_size == 0:
        raise ValueError(f'{bundle.name} has no executable')
    # lipo reads the actual Mach-O architecture, not the folder name.
    architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(executable)], text=True).split()
    if 'arm64' not in architectures:
        raise ValueError(f'{bundle.name} does not contain an iPhone arm64 executable')
    if bundle.suffix == '.appex':
        if info['CFBundlePackageType'] != 'XPC!' or not info.get('NSExtension'):
            raise ValueError(f'{bundle.name} is not a valid extension bundle')
    return info, version


def package(app, output):
    info, version = validate_bundle(app)
    if info['CFBundlePackageType'] != 'APPL':
        raise ValueError('The input is not an application bundle')
    for name, suffix, point in [
        ('ArcadeShareExtension', 'share', 'com.apple.share-services'),
        ('ArcadeKeyboardExtension', 'keyboard', 'com.apple.keyboard-service'),
    ]:
        extension, _ = validate_bundle(app / 'PlugIns' / f'{name}.appex',
                                       f"{info['CFBundleIdentifier']}.{suffix}", version)
        if extension['NSExtension']['NSExtensionPointIdentifier'] != point:
            raise ValueError(f'{name} has the wrong extension point')
    rust_symbols = subprocess.check_output(['xcrun', 'nm', '-g', str(app / info['CFBundleExecutable'])], text=True)
    if 'frb_get_rust_content_hash' not in rust_symbols:
        raise ValueError('The app is missing the linked Flutter/Rust core')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='arcade-ipa-') as temporary:
        payload = Path(temporary) / 'Payload'
        payload.mkdir()
        subprocess.run(['ditto', str(app), str(payload / app.name)], check=True)
        subprocess.run(['ditto', '-c', '-k', '--keepParent', str(payload), str(output.resolve())], check=True)
    with zipfile.ZipFile(output) as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError(f'IPA archive failed integrity check: {bad}')
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix('.ipa.sha256').write_text(f'{digest}  {output.name}\n')
    shutil.copyfile(Path(__file__).resolve().parents[1] / 'docs/ios-install.md',
                    output.parent / 'iPhone-installation.md')
    print(f'Unsigned IPA: {output.resolve()}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    package(args.app.resolve(), args.output)
