# Changelog

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
