# Desktop integration

The desktop adapter adds local clipboard capture, an optional system shortcut,
the picker overlay, and explicit copy or paste actions. Its capabilities are
session-dependent. Source support does not mean a platform path has been
validated on a user's machine.

## Clipboard behavior

Mesh synchronization never writes incoming clips to the operating system
clipboard. Clipboard writes happen only after an explicit user copy or picker
selection. A picker paste sets the selected text and then asks the native bridge
to restore the previously focused app and send its standard paste shortcut. A
failed paste leaves the selected text available for the app's copy fallback;
the adapter does not try to restore older clipboard contents on a timer.

On Windows, macOS, and X11, text changes observed by `clipboard_watcher` are
offered to the mesh capture callback only while the user has enabled desktop
capture. The watcher remains registered while capture is disabled, but events
return before reading clipboard data. On Hyprland, the app starts
`wl-paste --watch` only while capture is enabled and stops its whole process
group when capture is disabled or the app closes. The bundled helper checks
`CLIPBOARD_STATE` and requires `CLIPBOARD_TYPE` to identify a plain-text MIME
type before reading. Current `wl-paste --watch` behavior does not reliably set
`CLIPBOARD_TYPE`, so this capture path is a known blocker and must not be
advertised as working until verified/fixed. When both values are available, the
helper reads only `data` offers, skips cleared, sensitive, and empty offers,
and discards payloads above 32 KiB. Each event is length-framed,
so line breaks and trailing whitespace are preserved without treating clipboard
bytes as command arguments or logs. Hyprland capture needs `wl-clipboard` 2.2 or
newer and compositor support for the data-control protocol. Writes made by
explicit copy and paste actions are temporarily suppressed so those selected
mesh clips do not become new captures. These are text-only paths and do not
capture images or arbitrary clipboard formats.

## Platform support in source

| Session | Clipboard capture | Global shortcut | Focus restore and paste |
| --- | --- | --- | --- |
| Windows | `clipboard_watcher`, if startup succeeds and the user enables capture | `hotkey_manager`, if registration succeeds | Snapshots the HWND owner PID and process creation time, then revalidates the window identity before focus and immediately before `SendInput`. If Windows denies process metadata access or focus/input, the action fails closed and copy fallback remains available. |
| macOS | `clipboard_watcher`, if startup succeeds and the user enables capture | `hotkey_manager`, if registration succeeds | Requires Accessibility / post-event permission. Permission is requested only through the explicit access request, and rechecked when the app returns to the foreground. The saved application must still be running and the original PID must be frontmost immediately before key events are posted. |
| Linux X11 | `clipboard_watcher`, if startup succeeds and the user enables capture | `hotkey_manager`, if registration succeeds; the X11 keybinder runtime may be required | Requires `xdotool`. The native bridge checks the remembered window and verifies focus before sending Ctrl+V. Each `xdotool` subprocess has a two-second timeout. |
| Generic Wayland | Unsupported. A successful `clipboard_watcher` start is not treated as capture support. | Unsupported | Unsupported by the generic bridge. Copy fallback remains available. |
| Hyprland Wayland | Opt-in `wl-paste --watch` capture when wl-clipboard 2.2+ and the bundled helper are available; reads plain UTF-8 text only, skips sensitive/cleared/empty offers, and caps payloads at 32 KiB | Runtime Hyprland binding through `hyprctl`, when the compositor endpoint can be read and binding succeeds | Saves the active window address, PID, and Linux process start time; revalidates the client and process before injection. `hyprctl` commands have a three-second timeout. |
| Linux without a supported display | Best effort only if the watcher starts | Unsupported | Unsupported |

The Hyprland path uses the target window address and PID together. It reads the
process start time from `/proc/<pid>/stat` so PID reuse cannot redirect an old
target or shortcut to a different process. Shortcut changes install the new
binding before removing the old one; if the replacement fails, the old binding
is kept or restored where the compositor allows it. Unremoved shortcut commands
also carry the PID and start-time guard before signaling the app.

## Runtime verification

These platform paths have not been validated on live Windows, macOS, X11,
Wayland, or Hyprland sessions in this environment. In particular, the Hyprland
capture helper currently depends on an environment variable that `wl-paste`
may not provide. In particular, permission
prompts, compositor behavior, shortcut conflicts, clipboard watcher reliability,
focus policy, and input delivery need testing on each target OS/session before a
release describes them as runtime-verified integrations. Generic Wayland
clipboard capture and paste remain unsupported; the `wl-paste` watcher is used
only on Hyprland sessions where its data-control protocol is available.
