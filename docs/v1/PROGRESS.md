# Arcade Clipboard v1 progress

Detail for `qa-p1/Arcade-catalog` › `dev/v1/PROGRESS.md`. Newest first.

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
