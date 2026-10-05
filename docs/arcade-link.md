# Arcade Link

On the desktop, Arcade Clipboard works with the other Arcade apps (Box, Lens,
Look, Wheel) through [Arcade Link](https://github.com/qa-p1/Arcade-link).
Clipboard works exactly the same when no other Arcade app is installed.

The Rust core owns the Link: it writes the manifest and listens from
`initialize` (on a blocking task, off the startup path) and stops at
`shutdown`. Dart has no IPC code. It passes the settings in `initialize` /
`link_configure` and waits on `link_wait` for the few requests that need the
UI (show, quit, the picker).

## What Clipboard exposes

| Action | Accepts | Returns | Notes |
|---|---|---|---|
| `clipboard.add` | `text/*`, `file/image`, `file/any[]` | — | Puts the content into history, which syncs to all your devices (effect `sends-to-device`). A single PNG or JPEG becomes an image clip; other files travel as named files. Respects Private mode (`denied: private_mode`), the 16 MiB and 32-part limits (`too_large`, `maxBytes` 16 MiB in the manifest) and dedup (re-sending a clip moves it to the top). Text over the 32 KiB text field also travels in full as a representation, as desktop copies do. Never writes this computer's clipboard. Without devices set up: `unavailable`. |
| `clipboard.pick` | — | `text/*` or `file/*` | Opens the picker titled "Choose a clip for <app>"; the chosen clip goes back to the caller instead of being pasted. Images and files come back as handoff files owned by `arcade.clipboard`. Closing the picker answers `denied: user_cancelled`; cancelling the job closes the picker. A newer pick replaces an open one. |
| `clipboard.devices` | — | `structured/devices` | The other devices in your mesh: `[{name, platform, online}]`. No keys, IDs or addresses. |

Nothing exposes history contents unless you choose a clip in the picker.

## Isolated verification

The shared runner's `tools/e2e_checks/clipboard.py` group exercises the real
Linux bundle with a temporary profile, private D-Bus/keyring and Xvfb:

```sh
python3 ../../Rust/Arcade-link/tools/e2e.py --only clipboard
```

It verifies text, URL, PNG and multi-file additions, stored history kinds,
the 16 MiB limit and standard error messages, no-mesh availability, Private
mode, devices, picker selection, Escape and caller cancellation. The test
driver creates the mesh before starting the bundle; no live desktop is used.

## Settings

`link_enabled` ("Connect with other Arcade apps") and `link_disabled_peers`
(the per-app toggles) in the app's preferences. With the switch off,
Clipboard's manifest lists no actions and nothing listens.

## Command line

```sh
arcade-clipboard --version
arcade-clipboard --arcade-manifest   # the manifest (no side effects)
arcade-clipboard --quit              # quits the running instance
```

On Linux, `arcade-clipboard` is installed next to `clipboard` (a generic name
that can clash on `PATH`).

## Platforms

| | Linux X11 | Linux Wayland | Windows | macOS | iPhone, Android |
|---|---|---|---|---|---|
| `clipboard.add`, `clipboard.devices` | tested | build only | not built | not built | not a participant |
| `clipboard.pick` | tested (headless Xvfb) | build only | not built | not built | not a participant |

Phones aren't Link participants: there are no local sockets between apps and
they limit background work. They benefit anyway, because whatever a desktop
app sends with "Send to my devices" arrives in their history.
