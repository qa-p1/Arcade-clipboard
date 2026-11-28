# Arcade Clipboard v1 progress

Detail for `qa-p1/Arcade-catalog` › `dev/v1/PROGRESS.md`. Newest first.

## 2026-11-28 (cloud session) - 1.1.1 released

- #45 (09dede5): the key store message names the case (locked or missing) and what to install for this desktop
  (`lib/services/keyring_help.dart`, with tests).
- `v1.1.1-rc.1` (09dede5) [Release](https://github.com/qa-p1/Arcade-clipboard/actions/runs/46173950554) passed;
  [Gates](https://github.com/qa-p1/Arcade-clipboard/actions/runs/46175441105) with `previous: v1.1.0`: all 13 jobs
  passed.
- [Promote](https://github.com/qa-p1/Arcade-clipboard/actions/runs/46176217277) made `v1.1.1` from rc.1. Verified:
  the AppImage, tar.gz, dmg, Windows installer and SHA256SUMS.txt are byte for byte rc.1's; `arcade-release.json`
  and `manifest.json` differ only in channel, tag and notes link, and `manifest.json.sig` is added.

## 2026-11-23 (cloud session) - 1.1.0 released

- #37 (769a136): Link 1.1.1 offers in the clip menus and picker, **Send to my devices** on the card, catalog app
  list, the crypto and other dependency updates with byte-compatibility tests against 1.0.0.
- `v1.1.0-rc.1` (769a136) [Release](https://github.com/qa-p1/Arcade-clipboard/actions/runs/45186657831) passed;
  [Gates](https://github.com/qa-p1/Arcade-clipboard/actions/runs/45191227418) failed one job, the upgrade from
  1.0.0 with the user's data: `scripts/verify-upgrade.py` still clicked 0.3.2's Settings positions. Not promoted.
- #38 (e0337a3): the upgrade check drives 1.0.0's Settings (storage budget instead of item count, positions measured
  on 1.0.0); passed twice locally with the published 1.0.0 and the rc.1 AppImage (history, settings, history key
  and integration kept, ciphertext unchanged). README "Use it from anywhere".
- `v1.1.0-rc.2` (e0337a3) [Release](https://github.com/qa-p1/Arcade-clipboard/actions/runs/45199348785): the
  Android job failed once on Maven Central's HTTP 429 (Too Many Requests) while Gradle fetched its plugins; its one
  re-run passed. [Gates](https://github.com/qa-p1/Arcade-clipboard/actions/runs/45206610053) with
  `previous: v1.0.0`: all 13 jobs passed, including the upgrade from 1.0.0 with the user's data.
- [Promote](https://github.com/qa-p1/Arcade-clipboard/actions/runs/45208433855) made `v1.1.0` from rc.2. Verified:
  the AppImage, tar.gz, dmg, Windows installer and SHA256SUMS.txt are byte for byte rc.2's; `arcade-release.json`
  and `manifest.json` differ only in channel, tag and notes link, and `manifest.json.sig` is added. `v1.1.0` is the
  latest release and not a prerelease.

## 2026-11-21 (cloud session) - 1.0.0 released

- #35 (5218265): the launcher answers an unknown option with exit 2 and the usage, and `--arcade-manifest` without
  a display (D9). Tools 1.0.1's delta gate follows Tools' delta rule (Tools D25).
- `v1.0.0-rc.3` (5218265) [Gates](https://github.com/qa-p1/Arcade-clipboard/actions/runs/44948481242): all 13 jobs
  passed on the published files, `previous: v0.3.2`: published files and manifest, Linux conformance and the app's
  own checks, budgets, Windows and macOS smoke, the delta from 0.3.2 with signature and tampered chunk, N-1, **the
  upgrade from 0.3.2 with the user's history and keyring item**, Tier 1 Hyprland and Tier 2 KWin, Mutter, sway, X11.
- [Promote](https://github.com/qa-p1/Arcade-clipboard/actions/runs/44949154720) made `v1.0.0` from rc.3. Verified:
  the AppImage, tar.gz, dmg, Windows installer and SHA256SUMS.txt are byte for byte rc.3's (same SHA-256); only
  `manifest.json` and `arcade-release.json` differ (signed for stable), and `manifest.json.sig` is added. `v1.0.0`
  is the latest release and not a prerelease.

## 2026-11-18 (cloud session) - release candidates 1 and 2 (not promoted)

- #22 (e5ec844): `gates.yml` on Link `app-gates.yml@v1.0.13` (previous default v0.3.2), Tier 2 on Link 1.0.14 with
  an unlocked gnome-keyring, and `scripts/verify-upgrade.py` (0.3.2 → 1.0.0 keeps the history and the keyring item;
  passed locally against the published 0.3.2 and a CI AppImage; fails as it should when the history database or the
  keyring is missing).
- `v1.0.0-rc.1` (e5ec844) [Gates](https://github.com/qa-p1/Arcade-clipboard/actions/runs/44226756864): CLI-1 to
  CLI-4 failed with `GLIBC_2.3x not found`. `release.yml` built the Linux packages on ubuntu-24.04, while CI's Linux
  job and the 1.0.0 changelog say 22.04. #34 (163f958) builds them on 22.04.
- `v1.0.0-rc.2` (163f958) [Gates](https://github.com/qa-p1/Arcade-clipboard/actions/runs/44232113005): published
  files, N-1, budgets, Windows and macOS smoke passed. Failed:
  - Linux conformance CLI-2: `--arcade-conformance-unknown-flag` exits 0 with empty stderr (must exit 2 with the
    usage). CLI-4: `--arcade-manifest` exits 1 with empty stdout and stderr (must print the manifest and exit 0).
    CI's smoke runs `--arcade-manifest` under `xvfb-run` and passes, so the suspected cause is that conformance has
    no display and the answer comes from the Flutter side; the launcher should answer these itself. Not yet
    reproduced.
  - Tools' delta gate: the delta from 0.3.2 fetched 7,908,165 of 15,751,672 bytes (50.2%); the gate requires less
    than half. The update itself verified. To be aligned with Tools' own delta rule in Tools 1.0.1.
  - Upgrade, Tier 1 and Tier 2 were skipped (they wait on the Linux job): still never run on a published rc.
- Next: fix both, rc.3, Gates (previous v0.3.2), Promote only if every job is green. Detail in the catalog's
  `dev/v1/HANDOFF.md`.

## 2026-11-15 (cloud session) - step 5

- **Memory (step 5):** decisions in `docs/v1/DECISIONS.md` (D8). U1: the AppImage launcher moves a resident start to
  the unpacked copy (`<data>/arcade/runtime/clipboard-<version>-<key>/`) and exits; one-shot commands stay on the
  mount; a restart keeps the copy. W0/CB1a: the runner trims 5 s after the first frame and 2 s after each hide (Link's
  `arcade_trim.h`, vendored). CB2: `--restart` is answered by the runner through the core without starting the engine
  (`--version` and `--status` already were); `--arcade-manifest` still starts it (see D8). CB4: image cache 24 MiB.
  Not done: CB1b, CB3, retention, W1/W3b/OPEN1 (WebKit only). **Link stays at v1.0.8**: the tag v1.0.10 did not exist
  when this was written, so the dependency bump (and the uninstall that removes the copies) is still to do.
- **Tested locally** (Flutter 3.47.2 from the CI pin, Rust 1.98.1, Xvfb; Linux x86_64):
  - `python3 scripts/check-docs.py`: passed (71 local links, 63 vendored checksums).
  - `cargo +1.98.1 fmt --all --check`: clean.
  - `cargo +1.98.1 clippy --workspace --all-targets --locked -- -D warnings`: clean.
  - `cargo +1.98.1 clippy -p arcade_core --lib --locked --target x86_64-pc-windows-gnu -- -D warnings` and the same for
    `-p arcade-clipboard-launcher`: clean.
  - `cargo +1.98.1 test --workspace --locked`: all pass (launcher 7, core 88 passed and 1 ignored, relay 6 and 4).
  - `scripts/check flutter` (dart format, `flutter analyze`, `flutter test`): exit 0, 50 tests passed (3 new).
  - `scripts/dev build-linux`: built; `scripts/dev build-appimage --version 0.3.2`: built.
  - CI's AppImage smoke (`--version`, `--arcade-manifest` id): passed.
  - `scripts/verify-appimage.py` through Link v1.0.8's `tools/e2e.py run -- xvfb-run`: passed, including the new resident
    check (copy, launcher exit 0, no mount mappings, `--status`, `--restart`, `--quit`).
  - `tests/folder-migration.py` on the new bundle through the e2e runner: passed.
  - Trim by hand on the bundle under Xvfb (isolated Secret Service): RSS 302 to 169 MB at the startup trim, 251 to 180
    MB 2 s after a hide; a hide followed by a show 0.4 s later did not trim; `strace` counted two reads of
    `/proc/self/smaps` in that run. `--restart` without and with a resident: exit 1 with the old message, exit 0 and a
    new process, each in 20 ms with no display.
  - The new tests fail without their change: `starts_resident` always true (launcher test fails), the C ABI returning 0
    (core test fails), the cap at 100 MiB and the marker kept (Dart tests fail), the launcher's relaunch disabled
    (`verify-appimage.py` fails, "launcher must hand over ... and exit 0"). Without the restart-environment change the
    first run of `verify-appimage.py` failed at "the restarted resident to run from the unpacked copy"; that fix was made
    after seeing it, so it has no separate revert run beyond the Dart test.
- **Not run:** `tests/tray-registration.py` and `lifecycle_bridge_test.cc` (the tray test fails to start here:
  `ModuleNotFoundError: No module named '_dbus_bindings'` under `/usr/bin/python3`, which is 3.13; not diagnosed further); the Windows, macOS, Android and iOS
  jobs; the trim on a real GPU or Wayland desktop; Link v1.0.10 (tag missing); the runner without the trim, to compare.

## 2026-11-15 (cloud session) - step 4

- **Dead code (step 4):** decisions in `docs/v1/DECISIONS.md` (D7). Removed `Core::capture` (Rust), six unused Dart
  members (`searchText`, `displayCode`, `pairingApproved` with its write-only set, `maxItems`, `overlayBusy`,
  `disabledPeers`), `scripts/package-source.py` and the Android Studio file `clipboard_android.iml`. No behaviour
  change, nothing bridged touched (no bindings regenerated), no vendored file touched. Candidates kept are listed in D7.
- **Tested locally:**
  - `python3 scripts/check-docs.py`: passed (71 local links, 62 vendored checksums).
  - `cargo +1.98.1 fmt --all --check`: clean.
  - `cargo +1.98.1 clippy --workspace --all-targets --locked -- -D warnings`: clean.
  - `cargo +1.98.1 test --workspace --locked`: all pass (core 87 passed, 1 ignored; relay 6; others 5 and 4).
  - `scripts/check flutter` (dart format --set-exit-if-changed on the non-vendored files, `flutter analyze`,
    `flutter test`): exit 0, no issues, 47 tests passed.
  - Windows: `cargo +1.98.1 clippy -p arcade_core --lib --locked --target x86_64-pc-windows-gnu` could not run: the
    target installed, but `ring v0.17.14`'s build script fails with `failed to find tool "x86_64-w64-mingw32-gcc": No
    such file or directory`. The Windows-only code (`windows_login.rs`, the `windows_login_*` ops) was checked by hand:
    every function is called from `api.rs`.
- Windows, macOS and Android code compiles only in CI.

## 2026-11-14 (cloud session)

- **Untangle (step 2) started:** decisions in `docs/v1/DECISIONS.md`. D2: the vendored manifest script
  `scripts/arcade-release.py` is removed; Link's reusable publish writes `arcade-release.json` since step 6.
- **Step 6, release machinery (rule zero):** `release.yml` ran on every pushed `v*` tag and published it as the latest
  stable release, so a first `v1.0.0` tag would have reached users untested. It now has Tools' and Box's shape:
  "Tag a release" makes only `vX.Y.Z-rc.N` and starts "Desktop releases", which runs CI, builds every desktop
  package once and publishes them through Link's `app-publish` on the hidden `test` channel; "Promote" (Link
  `app-promote`) republishes a verified rc's bytes as stable with a signed manifest; "Nightly" republishes main
  CI's packages. The Inno installer keeps its switches through publish and promotion (`windows-installer: inno`,
  added to Link's reusable workflows for 1.0.8). The main-push nightly in `release.yml` is gone.
- **CB-5, second half:** `--status` answers from the Rust core before GTK and the engine start. The core exports
  `arcade_clipboard_status_line` (C ABI, the same `link::status_line` the Dart path printed); the runner's `main()`
  loads `lib/libarcade_core.so` beside itself for a lone `--status` and falls back to the engine path if it can't.
  Tests: a core unit test through the C ABI, and `verify-appimage.py` runs the installed `--status` with no display
  and asserts one JSON line and an empty stderr (before: GTK started and needed a display). The runner path was
  checked locally by compiling `main.cc` against the built core: headless answer, symlinked CLI, write failure
  (exit 1), missing core and extra arguments (engine path). The AppImage check runs in CI.
- **Link 1.0.8** (was v0.4.4): `Cargo.toml` pins `v1.0.8`, the lockfile follows, and `sync-design.py` copied the
  kit at the tag (compact key chips, RD-CLIPBOARD-2; colour-emoji fallback after Inter, CB-10; additive only).
  `assets/strings/install.json` matches Link's ("Just run it"), the CI lifecycle runner clones the pinned tag, and
  the shared installer and shortcut assets are byte-identical at v1.0.8 (VENDORED now names the tag). The new
  installer retires the old `dev.arcade.clipboard` launcher and login item, which the real-fleet e2e checks
  (`arcade_clipboard_update_retires_old_desktop_ids`, XFAIL until this is on main). Locally: clippy (1.98.1, clean),
  `cargo test --workspace` and `check-docs.py`.

## 2026-11-13 (local session)

- **Merged (#16):** `80f741d` C0/CB-3 (the picker never closes on blur), CB-4 (restart through `$APPIMAGE`), CB-1
  (`arcade-clipboard --overlay` banner); `7ad409f` CB-2 (folders become clips, oversize copies show a notice);
  `a4d6297` CB-7 (HTML-only copies get a plain-text rendering); `ab746fa` retention Forever with a 256 MB budget;
  `6eb63ea` Private mode visible in the picker, History and the tray badge, every change logs its cause; one clock
  reading per capture (Forever made a capture fail at random: "expiry must be within 30 days").
- **PR #17:** `cc2f1c0` CB-6 (header count and Clear follow the whole history, not the search); `0e98167` CB-9 (an
  empty Add clip shows its message once and typing clears it); `eb946ae` CB-8 (a dismissed startup notice stays
  dismissed); `c2f9e62` CB-5 (`--version` answers before GTK and the engine). Each with a test that failed before.
- **Tested locally:** `cargo test --workspace`, `cargo clippy -D warnings`, `scripts/check flutter` (analyze clean,
  40 tests). The Linux bundle and `verify-appimage.py` run in CI.
- **Open:**
  - CB-8's remote relay field "looks disabled": visual, needs a look on screen.
  - RD-CLIPBOARD-2 (shortcut chips stretch) and CB-10 (colour emoji) are in `lib/design/`, vendored from Link's
    design kit: they are fixed in Link and arrive with the next kit.
