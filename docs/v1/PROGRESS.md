# Arcade Clipboard v1 progress

Detail for `qa-p1/Arcade-catalog` › `dev/v1/PROGRESS.md`. Newest first.

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
  - CB-5 `--status` still starts the engine: it answers from a Link query that only the Dart/Rust side makes.
  - CB-8's remote relay field "looks disabled": visual, needs a look on screen.
  - RD-CLIPBOARD-2 (shortcut chips stretch) and CB-10 (colour emoji) are in `lib/design/`, vendored from Link's
    design kit: they are fixed in Link and arrive with the next kit.
