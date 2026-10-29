# Changelog

## 0.3.0 — 2026-10-29

The Arcade overhaul: Clipboard on the shared design kit and project standard.

- **New look.** The window, the quick picker, dialogs, welcome and pairing use
  the Arcade design kit, in light, dark and system themes. Settings follow the
  standard order: General, Shortcuts, Privacy, Sync, Connected apps, About.
  The remote relay applies on Enter or when you leave the field.
- **Quick picker.** Ctrl+Enter (⌘↩) pastes as plain text. Clicking elsewhere
  closes the picker. New default shortcut **Ctrl+Alt+V** (⌃⌥V on macOS);
  if you used Clipboard before, you keep your shortcut.
- **About.** Version, channel, who updates Clipboard, the user guide, the logs
  folder, Copy diagnostics and licences.
- **Icons and tray.** The Clipboard icon on every platform (the macOS icon was
  Flutter's logo). The tray shows the monochrome glyph, opens the window on a
  click and reads Open Arcade Clipboard, Settings, Private mode, Restart and
  Quit.
- **Folders.** Data moves to `~/.local/share/arcade/clipboard` (Windows
  `%APPDATA%\Arcade\Clipboard`, macOS `~/Library/Application Support/Arcade/Clipboard`)
  and settings to `settings.json`, on first start, copied and verified before
  the old folder goes. The app id is `dev.arcade.Clipboard`; on macOS, allow
  paste access again after updating.
- **Command line.** `--status`, `--show`, `--hide`, `--toggle` and `--restart`;
  launching Clipboard again shows the running copy on Windows and macOS too.
- **Android.** Release builds are signed with the release key, never the debug
  key; `jni_flutter` 1.0.4 (retracted) is now 1.0.4+1.
- **Relay.** Logs work (`RUST_LOG`, default info).
- Errors read "Couldn't …"; developer docs moved to `docs/dev/`.

## 0.2.5 — 2026-10-19

- `--arcade-manifest` now says how Clipboard is installed, as the other Arcade
  apps do. Without it Arcade Tools treated a Clipboard you installed yourself as
  one that can't install itself: adopting it downloaded and reinstalled the
  latest release instead of taking over your copy, and failed when the release
  couldn't be fetched.

## 0.2.4 — 2026-10-19

- The picker and a clip's actions no longer show a "Get · Ctrl+Alt+" button on
  every text clip. It was Arcade Tools' install action, which Clipboard uses
  only to get a missing app; pressing it on a clip only showed an error.
  Tools still installs a missing app when you choose Get in Connected apps.

## 0.2.3 — 2026-10-19

- A helper an app starts from its own image (such as a settings window) keeps
  working after the app quits: the previous release stopped passing the AppImage
  runtime's keep-alive pipe to every program, its own helpers included, so
  quitting could unmount the image under them. Now only programs from another
  image (the installed copy, other Arcade apps, a restart through the AppImage
  file) drop it, so installing from Downloads still leaves nothing behind.
- The AppImage's launcher, which runs `--install`, now releases the runtime's
  handles itself, so installing from Downloads no longer leaves the downloaded
  image's runtime running.

## 0.2.2 — 2026-10-19

- Installing or updating from your Downloads folder no longer leaves the
  downloaded AppImage mounted and its runtime running. The previous release
  stopped passing on the handle on the AppImage's mount, but the runtime also
  waits on a pipe the app inherits, and the installed copy still inherited that;
  now no inherited handle is passed on.

## 0.2.1 — 2026-10-18

- Updating or installing from your Downloads folder, and restarting no longer
  leave the old AppImage mounted and its runtime (about 20 MB) running. A
  program the app started inherited an open handle on its AppImage mount and
  kept it busy.
- `arcade-clipboard --help` prints the command-line options instead of opening
  the app.

## 0.2.0 — 2026-10-18

- Private mode: nothing copied while paused leaks to other devices afterwards,
  and devices resync when you resume.
- Deleted pins stay deleted on every device; history retention counts from when
  a clip was created; the pin clock is bounded.
- Searching is cheaper, and a newer search replaces one still running.
- Tray: Clipboard waits for a tray host that starts after it and never leaves a
  hidden window you can't reach; the tray menu shows a Private mode checkmark.
- `--settings` opens Settings; command-line answers go to the program that asked
  instead of overwriting a redirected file.
- Imported settings show the limits that were applied.
- Large rich text sent over Arcade Link keeps its formatting.
- One name everywhere ("Arcade Clipboard"), and relative times ("2 min ago")
  refresh while the window is open.
- Built against Arcade Link commit `2fc7c91`.

## 0.1.0 — 2026-10-14

First stable desktop release.

- End-to-end encrypted clipboard history across your devices: QR pairing,
  LAN discovery and an optional relay, pins, Private mode.
- Pairing preserves partially received approval frames when you confirm a
  device, preventing intermittent failures to establish the shared mesh.
- Arcade Link (desktop): Send to my devices, Choose a clip, device list, and
  clip actions offered by the other Arcade apps.
- Arcade Tools hub (Link `v0.3.0`): settings, restart, a Private mode tray
  item in Tools' combined tray, picker shortcut rebinding, settings
  export/import (never history or device keys), and tray hand-off while
  Tools hosts the tray.
- Linux AppImage that installs itself on first run (launcher entry, icon,
  `arcade-clipboard` command, optional start at login), with `--install`,
  `--uninstall`, `--repair` and `--integration-status`. The tarball is kept
  for this release.
- macOS offers Move to Applications; Windows installs per user with the
  shared Arcade installer.
- User guide in `docs/user/`.
