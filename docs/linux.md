# Linux

Hyprland is the main development platform and has the most complete integration. X11 desktops and other Wayland compositors are supported with the differences listed below.

## Requirements

Runtime:

- GTK 3. The release bundle includes its own copy of keybinder 3.
- A running Secret Service provider with an unlocked keyring, such as GNOME Keyring or KWallet. The device identity is stored there; the app refuses to start a profile whose key is missing rather than silently creating a new identity.
- Wayland: `wl-clipboard` 2.2 or newer (`wl-paste` and `wl-copy`).
- Hyprland: `hyprctl`, which ships with Hyprland. Both the Lua and the legacy configuration formats are supported.
- X11: `xdotool`, for returning focus to the previous window and pasting.

Build dependencies are listed in [Development](development.md#linux-prerequisites).

## Install and run

```bash
bash scripts/dev.sh build-linux     # release bundle and dist/Arcade-Clipboard-linux-x64.tar.gz
bash scripts/install-linux.sh       # copies it to ~/.local/share/arcade-clipboard
```

`install-linux.sh` adds a `dev.arcade.clipboard.desktop` entry so the app appears in your launcher. It does not edit shell or compositor configuration. To run the bundle without installing it, start `apps/flutter_app/build/linux/x64/release/bundle/clipboard`; keep the executable next to its `lib/` and `data/` directories.

Only one instance runs at a time. Launching the app again brings the existing window forward.

| Option | Effect |
| --- | --- |
| `--background` | Start without showing the window. Used by **Launch at login**. |
| `--overlay` | Open the picker in the running instance, or start the app and open it. Bind this to a shortcut on compositors without in-app shortcut support. |

| Environment variable | Effect |
| --- | --- |
| `ARCADE_DEBUG=1` | Print capture, picker, paste and connection events to stderr. Clipboard contents are never logged. |
| `ARCADE_DATA_DIR` | Use a different profile directory. Also allows a second instance, for example to pair two profiles on one machine. |
| `ARCADE_RELAY_URL` | Default relay address for new profiles. **Settings → Remote relay** overrides it. |

## Automatic capture

**Settings → Automatically add desktop copies** is on by default. **Private mode** pauses capture without changing that setting.

On Wayland, a small helper bundled with the app (`lib/arcade_clipboard_wl_capture`) runs `wl-paste --watch` and notifies the app whenever the clipboard changes. The app then lists the offered types and reads the most useful ones: plain text, HTML, PNG, JPEG and file lists. It skips content that the source app marks as sensitive, as KeePassXC and other password managers do with `x-kde-passwordManagerHint`. The helper exits as soon as the app does, so no stray `wl-paste` processes are left behind. If the watcher stops unexpectedly, the app restarts it with a short backoff.

On X11, the app listens for GTK clipboard ownership changes.

Clips that the app itself writes to the clipboard, for example when you paste from the picker, are not captured again. When the app starts, the current clipboard is added only if it is not already in history.

Compositors without the data-control protocol, most notably GNOME, do not let background apps read the clipboard. On those desktops capture is unavailable and Settings explains why. You can still add clips from the app.

## Shortcut and picker

The default shortcut is **Ctrl+Shift+Space**. Change it in **Settings → Mesh Clipboard Shortcut**. Shortcuts already taken by the compositor are reported as conflicts.

The picker lists recent clips with the newest selected:

| Key | Action |
| --- | --- |
| Up / Down, Home / End | Move the selection |
| Typing | Search |
| Enter or click | Paste the selected clip |
| Escape | Close without pasting |

### Hyprland

The app registers the shortcut at runtime with `hyprctl`. In Lua configurations this uses `hl.bind`, otherwise the legacy `keyword bind`. The binding belongs to the app and is removed when the app quits. Nothing is written to your configuration files.

The picker window is titled **Mesh Clipboard**. On first use the app adds a window rule for the current compositor session that floats, pins and centers that window at 430 × 510. The picker therefore opens in place and does not disturb your tiling layout. The main window keeps its normal title and tiles as usual.

When you choose a clip, the app:

1. Checks that the window you were using still exists, matching its address, process ID and process start time.
2. Writes the clip to the clipboard with `wl-copy`.
3. Focuses that window and sends Ctrl+V, or Ctrl+Shift+V when the window is a terminal (kitty, Alacritty, foot, WezTerm, Ghostty, Konsole and similar).

If automatic paste fails, for example because the window has closed, the clip is copied instead and the app asks you to press Ctrl+V.

### X11

The shortcut is a global keybinding through keybinder. Paste uses `xdotool` to restore focus to the remembered window and send Ctrl+V, or Ctrl+Shift+V for terminals.

### Other Wayland compositors

Wayland does not let apps register global shortcuts or type into other windows. Bind `clipboard --overlay` to a key in your compositor configuration, using the installed path. Choosing a clip copies it, and you press Ctrl+V yourself.

```ini
# Sway example
bindsym Ctrl+Shift+space exec ~/.local/share/arcade-clipboard/clipboard --overlay
```

## Background and login

**Keep running in the background** makes closing the window hide it to the tray instead of quitting. If there is no tray host, the window stays reachable and closing it quits the app. **Launch at login** writes `~/.config/autostart/arcade-clipboard.desktop`, which starts the installed app with `--background`.

The tray icon opens Settings on click. Its menu is the one every Arcade app has: **Open Clipboard**, **Open Settings**, **Restart Arcade Clipboard** and, below a separator, **Quit Arcade Clipboard**. Restart starts a new background instance, which waits for the old one to exit, then quits.

The app quits cleanly on the tray's Quit item, `SIGTERM` or `SIGINT`. It removes its Hyprland binding and stops the capture helper before exiting.

## Troubleshooting

Start the app from a terminal with `ARCADE_DEBUG=1` and repeat the action.

| Symptom | What to check |
| --- | --- |
| Copies are not added | The log should show `[capture] stored …` after each copy. If it shows nothing, check that `wl-paste --version` reports 2.2 or newer and that Private mode is off. Settings shows whether capture is available on your session. |
| "This clipboard profile is already open" | Another instance is using the same profile. Quit it, or use `ARCADE_DATA_DIR` for a second profile. |
| "Could not access the system credential store" | Unlock your keyring, or install and start a Secret Service provider. |
| The shortcut does nothing on Hyprland | Run `hyprctl binds` and look for the `Arcade Clipboard` entry. Another binding on the same keys takes priority; choose a different shortcut. |
| The picker opens tiled on Hyprland | A rule in your configuration matching `dev.arcade.clipboard` may override the app's rule. Restrict it to the title `Arcade Clipboard`. |
| Paste goes to the wrong place | The remembered window was replaced, for example by a browser tab that moved to a new window. The clip is still on the clipboard; paste it manually. |
| Other devices do not appear | Both devices must be on the same network and allow incoming TCP on the app's port, plus UDP 5353 for mDNS. Otherwise configure a relay. |
