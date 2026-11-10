# Spec 4: Arcade Clipboard 1.0.0 (desktop, Android, iOS)

**Outcome:** Clipboard 1.0.0 on Linux (first-class), Windows and macOS (beta), Android (APK in the release) and iOS
(unsigned IPA in the release, which the owner sideloads with 3uTools after v1 is out). It delivers:
- the picker never closes on its own;
- restart and quit are clean;
- every copy is captured or explained;
- history follows the user's own retention and storage budget;
- Private mode is always visible;
- desktop ↔ mobile sync works end to end.

Starting point: `qa-p1/Arcade-clipboard`, Clipboard 0.3.2 (Flutter app `apps/flutter_app`, Rust core
`libarcade_core`). Read `AUDIT/clipboard.md`, `AUDIT/real-desktop.md` §Clipboard and `AUDIT/FINDINGS.md` C0/C1.

## Findings to fix

| ID | P | What | Where |
|---|---|---|---|
| C0 / CB-3 / RD-CLIPBOARD-1 | P0 | The Ctrl+Shift+Space picker closes on blur 400 ms after showing. On Hyprland with `follow_mouse=1`, moving the pointer out closes it. It must close only on Escape, choosing a clip, the shortcut again, or an explicit outside click. | `lib/platform/desktop_adapter.dart:244-258` (`onWindowBlur`), `lib/services/app_controller.dart:1281` |
| CB-4 / C1 / RD-CLIPBOARD-3 | P0 | Restart starts `Platform.resolvedExecutable` (inside the AppImage mount). The successor runs from an unmounted image: unreachable, `--status` says `running:false`, and it SIGBUSes later. Restart must re-execute `$APPIMAGE` through Link's launcher, and join the tokio runtime before exit. | `lib/platform/desktop_adapter.dart:190-202` |
| CB-2 | P1 | Copied folders, files over 16 MB and file+folder lists are dropped with no notice and no log reason. Folders become clips; oversize copies show "Couldn't add … (over N MB)". | `lib/services/app_controller.dart:1425-1440` |
| CB-1 | P1 | The banner says `clipboard --overlay`; the command is `arcade-clipboard --overlay`. | `lib/platform/desktop_adapter.dart:2053` |
| CB-7 | P1 | HTML-only copies are stored as raw markup (Wayland) or as "Empty clip" (X11). Store a plain-text rendering, and keep the HTML as an extra representation. | capture path |
| CB-6 | P2 | Header count and the Clear button follow the search filter. | `pages/history.dart` |
| CB-8 | P2 | Settings wording: the remote relay field looks disabled; the capture notice reappears after every restart. | settings |
| CB-9 | P2 | Add clip: the empty-submit error shows twice and stays after typing. | add dialog |
| CB-5 | P2 | `--version` and `--status` start GTK/Flutter and print engine warnings. Answer before the engine starts. | `linux/my_application.cc` |
| CB-10 | P2 | Emoji renders as a tiny monochrome glyph. Use Link's colour emoji fallback font. | design kit |
| RD-CLIPBOARD-2 | P2 | Shortcut recorder chips stretch into full-width rows. | `lib/design/arcade_widgets.dart` |

## Owner decisions (README Round 5)

- **Retention is the user's choice.**
  - Keep for a chosen time, including Forever, within a storage budget the user sets. The default is Forever with
    256 MB.
  - When stored history exceeds the budget, the oldest unpinned clips are removed. Pinned clips are never removed
    automatically.
  - Settings shows the space used.
  - Migrate the current 1-day default: existing users keep their setting.
  - Count sqlite, WAL and blobs against the budget. Checkpoint the WAL after pruning (the audit saw a 12 MB DB plus
    7.7 MB of WAL for 14 clips).
- **Private mode is always visible.**
  - While it's on, the tray icon (badge), the History header and the picker show it, with a one-click "Turn off".
  - Audit every path that can turn it on (the owner's install was found ON with nothing captured since 19:13, cause
    unknown). Each such path logs the cause.
  - It is never turned on silently by another app. A Link request to pause capture is shown as "Paused by <App>",
    with a timeout.

## Mobile

- **Android:** same audit items where they apply, untangle and polish. The release ships an APK signed with the
  release key from secrets (never the debug key). Test on an emulator in CI: pair with a desktop instance, sync text,
  an image and a link both ways, and check that unpair works.
- **iOS:** build on a macOS runner and publish an unsigned `.ipa` in the release, marked beta. The CI build and unit
  tests must pass. Document sideloading with 3uTools in the README.
- **Sync crypto and pairing get the security review** (`README.md` §Security): key exchange, replay, relay trust, and
  invite expiry.

## Memory

`AUDIT/memory.md`: the Flutter engine costs about 73 MB PSS / 156 MB RSS, and destroying its view frees nothing.
Apply the Clipboard items in `AUDIT/memory.md`:
- keep history out of RAM;
- bound the image caches;
- decode thumbnails, not full-size images;
- trim after large clips.

Items U1, CB1a (in-process trim, 156/73 → 95/60), CB2 (answer CLI queries without starting Flutter), and CB3/CB4 (list rows without full text, `imageCache` ≤ 24 MiB, a windowed list). Budget: background 105 PSS / 130 RSS.
Moving the engine out of the always-running process (a small capture daemon plus a UI spawned on demand) costs
about 0.1–0.2 s on the first open after idle. Do it only if the fleet budget can't be met otherwise, and prewarm on
the shortcut press so the picker still opens instantly.

## CI

Measured: main CI takes 7–15 minutes. Add the Android emulator and iOS jobs without going past the PR target: run them on main and release only, with a fast PR-level analyze and test.

## Acceptance

All `PLAN.md` exit gates, plus:
- A harness test: picker open → pointer leaves → focus changes → it's still open; Escape closes it.
- `--restart` and tray Restart leave exactly one reachable instance, with no coredump.
- Retention and budget pruning tests.
- A Private-mode visibility test.
- Android emulator sync end to end.
- The iOS IPA builds.
