# Decisions

Newest last. Each entry: what was decided, why.

## D1. Link moves from v0.4.4 to the tag v1.0.8
`Cargo.toml` pins `arcade-link` `v1.0.8`; `scripts/sync-design.py` copied the design kit at the tag, and
`scripts/VENDORED` names it for the shared installer and shortcut assets (byte-identical to the earlier copies).
Why: the fleet rule "One launcher per app". 1.0.7's installer retires the old `dev.arcade.clipboard` launcher and
login item on update. 1.0.8 adds the compact key chips (RD-CLIPBOARD-2), the colour-emoji fallback (CB-10) and the
`windows-installer: inno` input that `release.yml` and `promote.yml` use.

## D2. The release manifest script goes; Link's publish writes the manifest (untangle)
`scripts/arcade-release.py` was a vendored copy of Link's manifest writer at `76883b3`, kept in step with Link by a
checksum. Since step 6, Link's reusable `app-publish.yml` writes `arcade-release.json` and `SHA256SUMS.txt` from the
built packages, so nothing ran the copy. It only had to be kept in step with Link's (a hidden link with no user). It
is removed, along with its checksum, its `.gitattributes` line and the manual command in `docs/dev/releases.md`.

## D3. The core module is split by concern (untangle)
`core.rs` (2,807 lines) pulled in `core_helpers.rs` (882 lines) with `include!`, so one 3,700-line module held four
concerns and the second file looked separate but shared every private item. It is now the directory module `core/`:
`mod.rs` (profile, history, settings, capture and the `request` dispatcher), `pairing.rs` (mesh creation,
invitations, both sides of the pairing handshake, revocation), `replication.rs` (item, delete, pin and membership
messages, chunked transfers, per-peer sync) and `peers.rs` (listener, hello handshake and `Bootstrap`, reconnect
and dialling, discovery, relay). Code was moved by line range with a script; a line-multiset check shows no line
lost or changed except `pub(super)` on items another part of `core` uses and the new module headers. The public
interface (`Core` and its `pub`/`pub(crate)` methods) is unchanged. `scripts/dev` no longer runs a separate `rustfmt` on `core_helpers.rs`: `cargo fmt --all`
did not reach an `include!`d file, and now every file is a module it formats.

## D4. The Hyprland code leaves the desktop adapter (untangle)
`desktop_adapter.dart` (2,462 lines) mixed the generic desktop work with fourteen methods, four fields and six
helpers that only drive Hyprland through `hyprctl`. They are now the class `Hyprland` in
`lib/platform/hyprland.dart` (shortcut bind and cleanup, paste target capture, checks and dispatches, picker window
rule and placement), which the adapter owns and gives its command runner. The picker's title and size, which
belonged to the adapter, are now arguments. Code was moved with a script; a line-multiset check shows only renames
(the `Hyprland` prefix dropped inside the class) and these changes:
- The second `SIGUSR1` listener install in the shortcut bind is removed. `initialize` installs the listener on Linux
  before it marks the adapter initialized, and `configureShortcut` refuses to run before that or after `dispose`, so
  the second install never ran. It was the only reason the Hyprland code needed the adapter's overlay callback.
- The `_isHyprland` check after clearing the bindings on dispose is removed. Bindings are only made on Hyprland, so
  off Hyprland the list is empty and the check never skipped anything.
`desktop_adapter.dart` is now 1,924 lines.

## D5. The Wayland clipboard read and write leave the desktop adapter (untangle)
The `wl-paste` read, the `wl-copy` write and their binary process runner used no adapter state apart from the two
tool paths, so they are now the functions `readWaylandClipboard` and `writeWaylandClipboard` in
`lib/platform/wayland_clipboard.dart`, which take the paths as arguments. Moved with a script; the line-multiset
check shows only the renames, the paths as arguments, and one removal: the read fell back to the native plugin when
`wl-paste` was missing, but its only caller reads through `wl-paste` only when it was found, so the fallback never
ran. `desktop_adapter.dart` is now 1,761 lines.

## D6. Building a clip from a desktop copy is a function the controller acts on (untangle)
`AppController._captureRichFromDesktop` (140 lines) read the copied files and formats, applied the 16 MB limit,
picked the kind and bounded the text, and in the middle of that called back into the controller to show the
"too large" notice or offer Link's photo compression. The reading and deciding is now `captureCopy` in
`lib/services/clip_capture.dart`, which returns what the copy becomes (`NothingToCapture`, `CopyTooLarge`,
`LargePhoto` or `ClipToCapture`, which builds the core's `capture` request), and the controller handles each
outcome as before. The statements are unchanged; the two early-return callbacks became returned outcomes. The
second hard-coded 16 MiB (the large-photo check) now uses the same `maxClipBytes`. `clip_capture_test.dart` covers
text, url, HTML-only (CB-7), folder (CB-2), blank and unkept formats, both over-limit outcomes, and the 32 KiB
text cut.

## D7. Dead code (step 4)
Removed, one commit each, with the proof in the commit body:
- `Core::capture` (Rust): a `pub` wrapper around `capture_representations` that nothing called. Proof: with `api` and
  `Core` made private in `lib.rs` for one build (reverted), rustc reports "method `capture` is never used" for the lib
  and the lib test build; it is not bridged (the bridge exposes only `api::call`, and the `capture` op goes through
  `request`). Every other `pub` method of `Core`, and every other item in the private modules, is already covered by
  rustc's dead-code lint, which CI turns into an error.
- `ClipboardItem.searchText`, `PairingInvite.displayCode`, `AppController.pairingApproved` (and the write-only
  `_approvedPairingSessions` set behind it), `AppController.maxItems`, `AppController.overlayBusy` and
  `LinkService.disabledPeers` (Dart). Proof: a script counted every identifier in `lib/`, `test/` and
  `integration_test/` with comments and strings stripped; each name occurred once, at its declaration. The vendored
  `lib/design/` and the generated `lib/src/rust/` were not touched.
- `scripts/package-source.py` and `apps/flutter_app/android/clipboard_android.iml`: no file in the repository names
  either (`git grep`), and no workflow, script, build file or doc runs them. The `.iml` is Android Studio metadata.

Checked and kept:
- All pubspec dependencies are imported; all Cargo dependencies of the four crates are used.
- Every platform channel method Dart calls has a native handler and every native handler has a Dart caller
  (`arcade_clipboard/desktop_bridge`, `/mobile`, `/instance`, `/answer`); every JSON op in `api.rs` is sent by Dart.
- Code under `cfg(windows)`, `cfg(target_os = "macos")` and `cfg(target_os = "android")` is reached from `api.rs`,
  `secret.rs` or `lib.rs`; the Windows check could not be run here (see PROGRESS).
- Candidates left for a decision, not removed:
  - `platform/desktop/arcade_desktop_bridge/linux/tests/clipboard_bridge_test.cc`: no workflow or script builds it
    (CI builds only `lifecycle_bridge_test.cc`). It is a test, so wiring it into CI is better than deleting it.
  - `scripts/bootstrap-toolchains.sh`: nothing names it, but it fills the `.tools/` directory that `scripts/dev-env.sh`
    falls back to, and it pins Rust 1.98.0 against `rust-toolchain.toml`'s 1.98.1. Update or remove it with the
    toolchain policy.
  - `services/relay` exposes `pub` items (`RENDEZVOUS_TTL`, `with_max_connections_per_ip`, `cleanup_loop`, `app`,
    `Health`) that only the crate itself uses; they could be `pub(crate)`, which is a visibility change, not a removal.
  - The bridge function `api::call` is the only bridged function and is used; nothing bridged was touched, so no
    bindings were regenerated.

## D8. Memory (step 5)
Source: the memory audit (`dev/v1/AUDIT/memory.md`: U1, W0, CB1a, CB2, CB4). Done on Linux only; Windows, macOS and
Android code paths are unchanged.

Done:
- **U1, unpacked runtime.** The AppImage launcher (`platform/linux/launcher/src/main.rs`) now calls
  `arcade_link::runtime::relaunch_unpacked("arcade.clipboard", installer::VERSION, false)` after the integration
  commands and the first-run prompt, and exits with its code. The image is copied once to
  `<XDG_DATA_HOME>/arcade/runtime/clipboard-<version>-<key>/`, `AppRun` runs from there with `ARCADE_UNPACKED=1`, and
  the launcher that started it exits 0, so no FUSE helper or mount stays behind. The version is
  `installer::VERSION`, the release version that also names the receipt; `release.yml` refuses a tag unless
  `Cargo.toml` and `pubspec.yaml` agree and passes the same value as `ARCADE_RELEASE_VERSION`, so the core, the
  launcher, the runner (`--version`) and the Flutter app all report the same version. `starts_resident` (pure, with
  tests) decides which starts keep a resident: `--version`, `--help`/`-h`, `--status`, `--arcade-manifest`,
  `--restart`, `--quit`, `--hide` and `--integration-status` do not and run from the mount (so a status poll never
  triggers the first extraction); a plain start, `--background`, `--show`, `--toggle`, `--overlay` and `--settings`
  do. In the copy the launcher skips the first-run prompt when `ARCADE_UNPACKED` is set (the launcher that handed over
  has already asked, as in Look), and `installer::bundled_app()` finds the Flutter bundle because it resolves
  `arcade-clipboard` beside `current_exe()`, which is the copy's own launcher.
- **Runner in the copy.** `release_mount_handles()` closes inherited handles that point into `$APPDIR` or a
  `.mount_*` path. Link detaches every descriptor above stdio from the copy (`detach_from_image`), so there is
  nothing left to release from the old mount; in the copy `$APPDIR` is the copy, and the function still marks any file
  the app itself holds there close-on-exec for the programs it starts, which is what it was for. It needs no change.
  `wait_for_predecessor()` reads `ARCADE_CLIPBOARD_RESTART_AFTER`, which passes through the launcher and the copy
  unchanged, so a restarted successor still waits for the old process before claiming the single instance.
- **Restart keeps the copy.** The tray's Restart (and `--restart`) starts `$APPIMAGE` with the environment of the old
  process. A resident in the copy has `ARCADE_UNPACKED=1`, which made the successor's launcher believe it already was
  the copy, so the successor ran from the mount for good; the packaged check below caught it. `DesktopAdapter`
  now drops the marker from the successor's environment only when the running executable is inside
  `arcade/runtime/clipboard-*` (`successorEnvironment`, tested). A harness that sets the marker on purpose (Link's e2e
  runner) keeps it.
- **W0 / CB1a, trim.** `apps/flutter_app/linux/runner/arcade_trim.h` is Link's `qt/arcade_trim.h` (v1.0.8, identical at
  v1.0.7, v1.0.9 and main), recorded with its SHA-256 in `scripts/VENDORED`, which `check-docs.py` verifies.
  `my_application.cc` calls `arcade_trim()` once 5 s after the first frame and 2 s after each hide of the main window,
  and a show cancels the hide's timer; nothing runs while hidden otherwise. The hook is the GTK window's `unmap` and
  `map` signals, not a Dart call through the bridge: every hide (the close button, the tray, `--hide`, the picker
  closing through `windowManager.hide()`) ends in `gtk_widget_hide`, which unmaps the window, so one place sees them
  all, with no new method channel call and no way for Dart to forget. A login start never maps the window, so the
  startup trim covers it. Minimizing (`gtk_window_iconify`, used only while no tray host exists) does not unmap the
  widget and is not trimmed. Measured on the Linux bundle under Xvfb (software GL, so absolute numbers are larger than
  on a real GPU): RSS 302 MB before the startup trim, 169 MB after; 251 MB at a hide, 180 MB 2 s later (it then
  grows again with the app's own work, e.g. 188 MB 8 s on). `strace` showed exactly two reads of `/proc/self/smaps` in a run with a hide that a show cancelled (the
  startup trim and the one after the last hide).
- **CB2, one-shot commands.** The audit's list was already half done: `--version` and `--status` answer in the
  runner's `main()` before GTK and the engine (CB-5). `--restart` is added the same way: the core exports
  `arcade_clipboard_restart_running` (the `link::call_running("app.restart")` the Dart path used), the runner loads
  `lib/libarcade_core.so` and answers in 20 ms without a display. Exit codes and the "isn't running" text are as before,
  and it falls back to the engine path if the core can't be loaded. These commands are answered by the runner rather
  than the Rust launcher on purpose: the launcher exists only in the AppImage, the runner answers in the bundle, the
  tarball and the AppImage alike, and the launcher is not linked with the core. Left as it was: `--arcade-manifest`
  (the engine starts). It reads the saved Link settings (`link_enabled`, disabled peers, the shortcut) from Flutter's
  shared preferences and first runs the data folder move, which needs the Dart settings code and the migration;
  answering it natively means re-implementing both in Rust, a larger refactor than this step.
- **CB4, image cache.** `main()` caps Flutter's image cache at 24 MiB (`lib/services/image_cache_limit.dart`); the
  history shows images through `Image.memory`.

Checked and not done:
- CB1b (the capture and store in a small resident daemon, with the Flutter UI started on demand) is the owner's call
  and a large change; nothing was started. CB3 (list rows without full text, windowing the list) and the retention
  change are not part of this step.
- W1, W3b and OPEN1 release WebKit's helper processes; Clipboard has none.
- Link stays at v1.0.8. `install::uninstall` only removes the app's own `arcade/runtime/clipboard-*` copies from Link
  v1.0.10, whose tag did not exist yet; until the bump, uninstall leaves the copy in the user's data folder.
  `verify-appimage.py` should assert that no `clipboard-*` copy is left after `--uninstall` once the dependency moves.
- Other apps that start Clipboard with their own `ARCADE_UNPACKED=1` in the environment (a Link client spawn from an app
  that runs from its copy) would keep Clipboard on the mount, because Link's `childenv::sanitize` does not drop that
  marker. That is Link's to fix; not touched here.
- Packaged check: `scripts/verify-appimage.py` had no resident start at all (every command in it is one-shot). It now
  starts the installed AppImage with `--background` and requires that the launcher exits 0, that exactly one runner
  runs from `<data>/arcade/runtime/clipboard-<version>-<16 hex>/usr/lib/arcade-clipboard/clipboard` with a
  `.complete` marker and no mapping from the mount or extraction folder, that `--status` reports it running, that
  `--restart` replaces it with another runner from the same copy, and that `--quit` ends it. It also removes
  `ARCADE_UNPACKED` from the environment it builds, so the check does not depend on the caller. Link's e2e harness
  sets that marker only for the apps it starts itself.
