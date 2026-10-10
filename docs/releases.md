# Desktop releases

The release workflow defines stable (`v<version>` tags) and nightly (pushes to
`main`) channels. A manual run can choose either channel; stable must run on a
version tag matching both Cargo.toml and pubspec.yaml. Nothing is tagged, pushed
or published by local development. CI builds the Windows and macOS desktop apps
and runs the Rust core tests on them; their installers and interactive behavior
are not yet verified.

## Shared Link dependency

The core takes Arcade Link as a git dependency pinned to a release tag
(`qa-p1/Arcade-Link`, `v0.2.0`, in the workspace `Cargo.toml`), so no workflow
needs a second checkout. To build against a local Link checkout, use the
`[patch]` override described next to the dependency. Moving to a newer Link
means changing the tag and refreshing `Cargo.lock`.

## Packages and installation

| Platform | Asset | Install |
| --- | --- | --- |
| Linux x64 | `Arcade-Clipboard-<version>-x86_64.AppImage`, kind `appimage` | Run the AppImage in place. The release manifest includes `installArgs` for the planned Link install flow; this Clipboard version does not yet implement `--install` or `--uninstall`. |
| Linux x64 (transition release only) | `Arcade-Clipboard_<version>_linux_x64.tar.gz`, kind `tarball` | Extract it and run `bash install-linux.sh`; it copies the full bundle into your XDG data directory and writes a per-user desktop entry. This asset is planned to be removed after one release. |
| Windows x64 | `Arcade-Clipboard_<version>_windows_x64-setup.exe`, kind `inno` | Run the per-user installer. For silent use: `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER`. |
| macOS | `Arcade-Clipboard_<version>_macos_<arch>.dmg`, kind `dmg` | Mount the image and copy Arcade Clipboard.app to `~/Applications`. This build is not notarized; no quarantine or OS security controls are changed automatically. |

The AppImage includes the Flutter release bundle, Rust core, keybinder library,
desktop entry, and the app icon as scalable SVG plus hicolor PNG sizes. Its
`AppRun` adds only the bundled `lib/` directory to `LD_LIBRARY_PATH`; GTK is
loaded from the host. The tarball remains available for the transition release
and includes both `install-linux.sh` and the previous `install.sh` entry point.
Linux needs GTK 3 and an unlocked Secret Service keyring. Uninstallation keeps
your encrypted data.
The iOS IPA remains a separate CI artifact, outside the desktop manager.

Every desktop release includes `arcade-release.json` (schema 1, Link v1, channel,
platform, architecture, installer kind, install arguments and SHA-256) and
`SHA256SUMS.txt`. The manifest script is vendored unchanged from Link commit
`76883b3`; provenance and its checksum are in `scripts/VENDORED`.
`--windows-installer inno` selects the correct silent flags.

## Local Linux packaging verification

```sh
CARGO_BUILD_JOBS=3 bash scripts/dev.sh build-linux
bash scripts/dev.sh build-appimage --version 0.1.0
python3 scripts/package-desktop.py --platform linux --version 0.1.0
python3 scripts/arcade-release.py --id arcade.clipboard --version 0.1.0 \
  --channel stable --windows-installer inno \
  --notes https://github.com/qa-p1/Arcade-clipboard/releases/tag/v0.1.0 dist/packages
(cd dist/packages && sha256sum -c SHA256SUMS.txt)
```

Use the isolated ecosystem runner for any install/launch verification. Never run
the installer or GUI in the owner's desktop session during development.
