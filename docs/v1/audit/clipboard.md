# Arcade Clipboard 0.3.2 audit

Environment: isolated HOME/XDG/runtime dir + private dbus + private gnome-keyring, Xvfb :93 (no window manager) for the Flutter UI,
plus a private headless sway (wayland-1 inside the private runtime dir) as the Wayland data-control source. Copies were made with
wl-copy and a small C data-control offerer (multi-MIME, used for the sensitive hint). Evidence: AUDIT/clipboard/n-*.png.

## Coverage
| Feature | Tested? | Method / input | Result |
|---|---|---|---|
| First-run welcome + "Start on this device" | yes | GUI | pass (n-start, n-setup1, n-hist0) |
| Capture plain/unicode/URL/multiline text | yes | wl-copy | pass; multiline collapsed to one line in row |
| Duplicate text bumps to top | yes | same text twice | pass |
| Whitespace-only / empty copy | yes | wl-copy | ignored (ok) |
| HTML-only copy | yes | wl-copy --type text/html | stored as "<b>bold</b> html" doc-icon row (see CB-7) |
| Image png 9 kB / jpeg 3.8 MB | yes | wl-copy | pass, thumbnails |
| 5 MB text, 270 kB base64 text | yes | wl-copy | stored, row truncated (ok) |
| File URIs (file + dir, symlinks, unicode name, 20 MB, broken link) | yes | text/uri-list | see CB-2 |
| Sensitive clip (x-kde-passwordManagerHint=secret alongside text) | yes | C data-control offerer | not captured (pass) |
| 500-item limit / pinned retention | yes | 560 real GTK/X11 clipboard changes at 110 ms, read-only sqlite + GUI | pass: exactly 500 items, 1 pinned + 499 unpinned; r-limit-db.txt, r-limit-500.png, r-limit-pinned.png |
| Search (case, accents, no result) | yes | GUI typing | pass; header count follows filter (CB-6) |
| Pin / unpin | partly | row menu | pin icon shows (pass); Pinned filter not re-verified |
| Row menu (Inspect/Pin/Share again/Delete) | yes | GUI | present |
| Detail dialog (file, image, text) | yes | GUI | opens; Esc closes (pass) |
| --version / --status | yes | CLI | CB-5 |
| --quit in isolation | yes | CLI | no crash (see CB-4) |
| Add clip dialog (empty, text) | yes | GUI | works; empty shows error twice (CB-9) |
| Delete clip, Clear (unpinned) history dialog | yes | GUI | pass; pinned clip kept |
| Devices page, Invite dialog (QR, Copy invite, expiry) | yes | GUI | opens, QR shown; no real pairing |
| Settings page (General/Shortcuts/Privacy/Sync/Connected apps) | yes | GUI, scrolled | renders; see CB-8 |
| Quick picker (--overlay): open, Esc, Down/Enter | yes | CLI + xdotool | opens, Esc closes, Enter copies full 5 MB clip to wl clipboard; focus-loss close now reproduced (CB-3) |
| --restart | yes | CLI | CB-4 |
| Idle CPU / threads / memory, files written | yes | /proc, 30 s | see Backend |
| Tray, global shortcut, paste into other window, Hyprland bind | no | needs real compositor | Unconfirmed section |
| Real pairing, mobile apps | no | out of scope | - |

## Findings

### CB-1 (polish) Banner and hint name the wrong command
Method: GUI. First-run and history banner: "Bind a system shortcut to "clipboard --overlay"". The installed command is `arcade-clipboard` (settings page and CLI help say that). Expected `arcade-clipboard --overlay`.
Source: apps/flutter_app/lib/platform/desktop_adapter.dart:2053. Evidence: n-hist1.png.

### CB-2 (wrong result) Some copied files are silently dropped, with no notice and no log reason
Method: GUI + data-control offer of text/uri-list. Inputs and results:
- file + directory in one list: only the file is stored, directory silently missing (n-menu-file.png, n-detail-file.png).
- directory alone: no clip created.
- 20 MB file: no clip created, no message (limit is 16 MB, "Up to 16 MB per clip" only appears in Add clip).
- broken symlink: dropped (acceptable), good symlink stored under the link name.
Expected: a visible "Couldn't add ..." notice (or a folder clip). diagnostics.log shows "read clipboard" then nothing.
Source: apps/flutter_app/lib/services/app_controller.dart:1427-1437 (`File(path).exists()` is false for directories, `size > 16 MB` returns silently).

### CB-3 (UX) Quick picker dismisses on an ordinary focus change
Method: **reproduced GUI in private Xvfb**, using explicit X11 focus (no WM needed). Open Clipboard with History visible, run `--overlay`, wait >400 ms, then focus the private `Audit Receiver` window using `DISPLAY=:93 xdotool windowfocus <receiver-id>`. The picker disappears and History reappears. Expected under the owner rule: picker stays open until an explicit dismissal or selection. Pointer leave alone without focus change stays open; focus-follows-mouse can turn that into pointer-leave dismissal, which still needs real compositor verification.
Source: `apps/flutter_app/lib/platform/desktop_adapter.dart:244-258` calls `onOverlayFocusLost` from `onWindowBlur` after 400 ms; `app_controller.dart:1281` dismisses. Evidence: `clipboard/r-picker-before-blur.png` and `r-picker-after-blur.png`.
Other saved popup checks (Add clip, Invite, Clear history, Inspect, row menu) stayed open until dismissed. Further focus tests continue below.

### CB-4 (broken) Restart (CLI --restart and tray "Restart") leaves a dead successor and is the likely source of the SIGBUS cores
Method: CLI in isolation. Steps: start `Arcade-Clipboard.AppImage --background`, run `--restart`. Result: diagnostics.log shows "[link] request restartRequested" then "[lifecycle] quitting"; the new process (cmd `.../usr/lib/arcade-clipboard/clipboard --background`) stays alive but writes no log, `--status` says running:false, `--overlay`/`--show` do nothing, no Link socket is created. /proc/<pid>/root has no /usr/lib/arcade-clipboard any more: the successor runs from the previous AppImage mount which was unmounted when the old AppImage runtime exited.
Cause: restart() starts `Platform.resolvedExecutable` (the inner binary inside the mount) instead of `$APPIMAGE` (desktop_adapter.dart:194-199).
Item (e): a normal `--quit` in isolation does NOT crash (5 runs: idle, after heavy use, quit during a 3.8 MB capture; no coredump). The two existing SIGBUS cores (17:48 and 18:39 today, coredumpctl, PID 88197: thread tokio-rt-worker, libarcade_core.so+0x2a1ffc, command line "clipboard --background", signal 7 BUS_ADRERR) match a process executing from an unmounted AppImage, i.e. the restart successor (the "[lifecycle] quitting" line is also what restart logs). Fix: restart via $APPIMAGE (or the launcher), and join the tokio runtime before exit(0).

### CB-5 (polish) CLI queries start GTK/Flutter and print engine warnings
Method: CLI. `--version` and `--status` take ~0.24 s and write 5 stderr lines (MESA-EGL DRI3 warnings, Atk-CRITICAL plug_id) while the answer is on stdout. Noisy for scripts. Source: linux runner my_application.cc (ARCADE_ANSWER_FD path).

### CB-6 (polish) Header count and Clear button follow the search filter
Method: GUI. Searching "zzzz": header "0 clips - not synced with other devices yet" although 13 exist, and "Clear history..." is disabled. Source: pages/history.dart.

### CB-7 (UX) HTML-only copy stored as raw markup
Method: wl-copy --type text/html '<b>bold</b> html'. Row shows the literal "<b>bold</b> html" with a document icon. Plain-text fallback is expected when no text/plain exists (strip tags).

### CB-8 (UX) Defaults and settings wording
- Default "Keep history" is 1 day (core DEFAULT_RETENTION_HOURS 24, settings.dart:205); unpinned clips silently vanish after a day, no "Forever" choice (max 30 days). Owner should confirm this default.
- Shortcuts row says "This desktop doesn't let apps register a global shortcut" under this X11/Xvfb session; the real Hyprland behaviour must be checked on the real desktop.
- The green capture notice is shown on History and Devices and re-appears after each restart.
- Remote relay field renders greyed like disabled (n-settings2 / s.png) while editable per spec.

### CB-9 (polish) Add clip: empty submit shows the error twice, and it stays after typing
Method: GUI. Add clip with empty text: "Enter something to share." appears in the dialog AND as a page banner behind the scrim; typing text keeps the old error until submit.

### CB-10 (polish) Emoji renders as a tiny monochrome glyph in rows ("😀" in n-scroll.png). No colour emoji fallback font bundled.

## Backend
- Idle 30 s with window shown after heavy use: 0.23 % CPU, 92 threads, RSS 525 MB (owner's real background instance: 70 threads, 116 MB). RSS is large after holding a 3.8 MB JPEG and 5 MB text.
- Files written: cfg/arcade/clipboard/settings.json, data/arcade/clipboard/{history.sqlite(+wal/shm), logs/diagnostics.log, profile.lock}, data/arcade/apps/arcade.clipboard.json, cache/mesa_shader_cache (GL). Nothing outside arcade folders except mesa cache and keyring file (private keyring, expected). history.sqlite 12 MB + 7.7 MB WAL for 14 clips (encrypted blobs).
- Secret Service: private gnome-keyring in the private bus worked.
- Diagnostics log has no clip contents (good) but no reason text for dropped clips (CB-2).

## Unconfirmed / needs real desktop
- Focus-follows-mouse pointer-leave on a real compositor (CB-3 focus-loss itself is reproduced).
- Global shortcut Ctrl+Shift+Space registration, tray left/right click, paste into another window, start at login, Hyprland binding.
- Real pairing and sync of text/image/link between two devices.
- Retention expiry (time-based; not waited).

## Resume checkpoint (private X11 only)
Confirmed capture of plain text, Hindi/Greek/accented Unicode/emoji, URL, PNG, HTML+plain, HTML-only and file URI lists with a real X11 selection owner (`resume/bin/xowner`). Sensitive `x-kde-passwordManagerHint=secret` alongside text was skipped: diagnostics reports `0 formats, sensitive=true`. No Wayland command was used during the resumed tests. HTML-only is titled **Empty clip** on X11, versus literal markup in the saved private-Wayland test (CB-7); there is no readable text preview. The 500-item cap and pinned exclusion are now exercised with 560 distinct clipboard changes; exact result: 500 rows including the 1 pinned marker. Evidence r-capture-*.png, r-limit-*. The private keyring is independent of the owner's keyring.
