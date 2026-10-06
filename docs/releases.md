# Desktop releases

The release workflow defines stable (`v<version>` tags) and nightly (pushes to
`main`) channels. A manual run can choose either channel; stable must run on a
version tag matching both Cargo.toml and pubspec.yaml. Nothing is tagged, pushed
or published by local development. Windows/macOS are **build only (CI defined,
not run here)**; their builds, installers and runtime behavior remain unverified.

## Shared Link dependency: owner action before CI

The relative Cargo dependency stays `../../Rust/Arcade-link/crates/arcade-link`.
Workflows check out Clipboard at `App dev/Arcade-clipboard` and Link at
`Rust/Arcade-link`, preserving that layout. The owner must publish Arcade-link,
then set repository Actions variables:

- `ARCADE_LINK_REPOSITORY`: the shared repository (default `qa-p1/Arcade-link`).
- `ARCADE_LINK_REF`: an immutable commit or tagged v1 release (default
  `1ae6ffbf7c75076772723f763a3d2da030207379`).

A failed/missing checkout ends the job with a message identifying those variables
and the owner action. This is expected until the shared repository is published.
The same setup supports the existing iPhone workflow. Before pushing, follow the
plan's separate owner action to replace local path dependencies with a tagged
git dependency and local development patch.

## Packages and installation

| Platform | Asset | Install |
| --- | --- | --- |
| Linux x64 | `Arcade-Clipboard_<version>_linux_x64.tar.gz`, kind `tarball` | Extract it into a new directory and run `bash install.sh`; it copies the full bundle into your XDG data directory and writes a per-user desktop entry. |
| Windows x64 | `Arcade-Clipboard_<version>_windows_x64-setup.exe`, kind `inno` | Run the per-user installer. For silent use: `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER`. |
| macOS | `Arcade-Clipboard_<version>_macos_<arch>.dmg`, kind `dmg` | Mount the image and copy Arcade Clipboard.app to `~/Applications`. This build is not notarized; no quarantine or OS security controls are changed automatically. |

Linux also runs in place with `./arcade-clipboard`; keep `lib/` and `data/`
beside it. Linux needs GTK 3 and an unlocked Secret Service keyring. The bundle
includes keybinder and its license. Uninstallation keeps your encrypted data.
The iOS IPA remains a separate CI artifact, outside the desktop manager.

Every desktop release includes `arcade-release.json` (schema 1, Link v1, channel,
platform, architecture, installer kind and SHA-256) and `SHA256SUMS.txt`. The
manifest script is vendored unchanged from Link commit `539fa91`; provenance is
in `scripts/VENDORED`. `--windows-installer inno` selects the correct silent flags.

## Local Linux packaging verification

```sh
CARGO_BUILD_JOBS=3 bash scripts/build-linux.sh
python3 scripts/package-desktop.py --platform linux --version 0.1.0
python3 scripts/arcade-release.py --id arcade.clipboard --version 0.1.0 \
  --channel stable --windows-installer inno \
  --notes https://github.com/qa-p1/Arcade-clipboard/releases/tag/v0.1.0 dist/packages
(cd dist/packages && sha256sum -c SHA256SUMS.txt)
```

Use the isolated ecosystem runner for any install/launch verification. Never run
the installer or GUI in the owner's desktop session during development.
