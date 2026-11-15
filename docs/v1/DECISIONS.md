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
