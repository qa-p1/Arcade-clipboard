# Arcade Link

On the desktop, Arcade Clipboard works with the other Arcade apps (Box, Lens,
Look, Wheel) through [Arcade Link](https://github.com/qa-p1/Arcade-link).
Clipboard works exactly the same when no other Arcade app is installed.

The Rust core owns the Link: it writes the manifest and listens from
`initialize` (on a blocking task, off the startup path) and stops at
`shutdown`. Dart has no IPC code. It passes the settings in `initialize` /
`link_configure` and waits on `link_wait` for the few requests that need the
UI (show, quit, the picker). `app.status` reports `status.mode` as
`background` or `foreground`, captured once from the startup flag. Showing a
window later does not change how Tools relaunches this instance.

## Actions on your clips

Desktop history menus and the picker offer these actions when the peer is
installed and enabled. The picker uses Ctrl+Alt plus the letter shown below.
Every entry shows the peer's glyph, ↗, and a preview of the selected clip.

| Clip | Action | Peer | Picker key |
|---|---|---|---|
| Image, file(s) | Quick Look | Look | Q |
| Image | Analyze with Lens / Pin | Lens | A / P |
| Image | Extract text | Lens | E |
| Image | Convert to PNG / Compress | Box | N / C |
| Text / JSON (peer accepts `text/plain`) | Format JSON / Clean text | Box | J / T |

Extracted text and Box results become new clips, using the existing capture,
validation, encryption, dedup and device sync path. They never write the local
system clipboard. Private mode denies these requests. Secret hints and Lens
secret findings prevent importing a result into the mesh.
Box's Format JSON returns `structured/json` with formatted text; Clipboard
stores that specific result as a text clip. Other structured outputs remain
metadata and are not imported.

Discovery uses `SharedRegistry` with an OS directory watch. `link_offers`
provides cached actions, `link_peers` provides settings rows; menu opening
makes no file or IPC calls. Missing/disabled peers are hidden. Unavailable actions are hidden. Oversized actions and Private mode disable
available entries with their standard reason. Dart sends
`link_invoke` and receives `invoke_progress` / `invoke_done` through
`link_wait`; `link_cancel` cancels the active request. IPC, probes, staging and
handoff reads/writes run on Rust workers. Active jobs have a 120-second
deadline (ordinary invoke replies retain the protocol client's 30-second
read timeout); there are no idle polling timers.

Copied photos between 16 and 32 MiB can wait locally for an opt-in **Compress**
when Box's image compressor is available. They are never inserted into history
or sent uncompressed. In-memory photos are staged in private handoff files in
512 KiB chunks; existing image files are passed by path. Discard, replacement,
completion and shutdown remove staging. The native clipboard reader's 32 MiB
cap stays in place. With no usable compressor, capture keeps its existing
16 MiB behavior. Mesh payload limits are unchanged.

Clipboard keeps an outbound handoff alive through peer completion and result
import, then removes it. Returned picker files instead retain the existing
24-hour cleanup policy because the caller reads them after the pick completes.

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

Settings → **Connected apps** lists every desktop Arcade app, its version and
running/installed state, and **Use with Arcade Clipboard** toggles. **Get**
invokes the registered manager's available `tools.install` with `options.app`;
otherwise it opens that app's release page. Promotion appears only here.
Diagnostics show the registry, listener, OS watcher and last error. The shortcut
recorder warns **Used by Arcade Box** (or the owning peer), using the cached
registry and normalized modifiers; saving a clash requires **Use anyway**.

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
| `clipboard.add`, `clipboard.devices` | tested | build only | build only (CI defined, not run here) | build only (CI defined, not run here) | not a participant |
| `clipboard.pick` | tested (headless Xvfb) | build only | build only (CI defined, not run here) | build only (CI defined, not run here) | not a participant |
| Item actions / progress / cancel | real peers and failure mocks (Xvfb) | build only | build only (CI defined, not run here) | build only (CI defined, not run here) | hidden |

Phones aren't Link participants: there are no local sockets between apps and
they limit background work. They benefit anyway, because whatever a desktop
app sends with "Send to my devices" arrives in their history.
