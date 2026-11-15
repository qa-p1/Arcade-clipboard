# Desktop releases

Stable is never built: it is a verified release candidate promoted byte for byte (Link spec §CI, the fleet's rule
zero).

1. Bump the version in `Cargo.toml` and `apps/flutter_app/pubspec.yaml` on `main`.
2. Run "Tag a release" (`tag.yml`) with `vX.Y.Z-rc.N` and the commit SHA on `main`. It creates the tag and starts
   "Desktop releases" (`release.yml`) on it, which runs CI, builds the Linux AppImage and tarball, the Windows Inno
   installer and the macOS dmg once, and publishes them through Link's `app-publish` as a hidden prerelease on the
   `test` channel, which Tools never offers.
3. Run every exit gate against those published files.
4. Run "Promote" (`promote.yml`) with the rc tag. Link's `app-promote` republishes the same files as `vX.Y.Z` on the
   stable channel with a signed `manifest.json`, then downloads them again and compares every hash.

"Nightly" (`nightly.yml`, daily) publishes main CI's already-tested packages as a signed `vX.Y.Z-nightly.*`
prerelease when `main` has changed and its CI is green. Nothing is tagged, pushed or published by local development.
CI builds the Windows and macOS desktop apps and runs the Rust core tests on them; their installers run install,
repair and uninstall smoke checks in disposable CI profiles. Interactive behavior on Windows and macOS has not been
verified.

## Shared Link dependency

The core takes Arcade Link as a git dependency pinned to a commit
(`qa-p1/Arcade-Link`, `4c75f3a`, in the workspace `Cargo.toml`), so no workflow
needs a second checkout. To build against a local Link checkout, use the
`[patch]` override described next to the dependency. Moving to a newer Link
means changing the pinned commit and refreshing `Cargo.lock`.

## Packages and installation

| Platform | Asset | Install |
| --- | --- | --- |
| Linux x64 | `Arcade-Clipboard-<version>-x86_64.AppImage`, kind `appimage` | Run the AppImage and choose Install, or use `--install --silent --no-launch`. The launcher, CLI, icons and receipt are written together. `--repair` restores them; `--uninstall` keeps data unless `--remove-data` is specified. |
| Linux x64 (transition release only) | `Arcade-Clipboard_<version>_linux_x64.tar.gz`, kind `tarball` | Extract it and run `bash install-linux.sh`; it copies the full bundle into your XDG data directory and writes a per-user desktop entry. This asset is planned to be removed after one release. |
| Windows x64 | `Arcade-Clipboard_<version>_windows_x64-setup.exe`, kind `inno` | Run the per-user installer. For silent use: `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER`. |
| macOS | `Arcade-Clipboard_<version>_macos_universal.dmg`, kind `dmg` | Mount the image and copy Arcade Clipboard.app to Applications. The app and Rust core support Apple silicon and Intel; packaging verifies every bundled native library. Updates keep the recorded Applications folder. This build is not notarized; no quarantine or OS security controls are changed automatically. |

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
`SHA256SUMS.txt`. Link's reusable publish (`app-publish.yml`) writes both from
the built packages; `windows-installer: inno` gives the manifest Inno's silent
switches, and promotion keeps the rc's installer kind.

## Local Linux packaging verification

```sh
CARGO_BUILD_JOBS=3 bash scripts/dev build-linux
bash scripts/dev build-appimage --version 0.1.0
python3 scripts/package-desktop.py --platform linux --version 0.1.0
```

Use the isolated ecosystem runner for any install/launch verification. Never run
the installer or GUI in the owner's desktop session during development.
