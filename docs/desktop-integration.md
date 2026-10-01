# Desktop integration

The Flutter DesktopAdapter combines native capabilities with window_manager and the platform shortcut provider. The app initializes capture in the disabled state; Settings explicitly opts into capture.

Windows uses native clipboard listeners/formats, target identity checks and paste injection. macOS uses NSPasteboard, pasteboard change notifications while capture is enabled, target focus and permission-sensitive paste. Linux uses GTK/X11 or bounded wl-clipboard helpers. Text, HTML/RTF, PNG/JPEG and local-file content can be retained together.

## Picker flow

1. Record the prior target.
2. Show the compact picker and select the newest item.
3. Navigate with arrows, Home/End or search.
4. Enter/click selects; Escape dismisses.
5. Hide the picker, restore/verify target focus and request paste.

On Hyprland the picker maps under the title “Mesh Clipboard”, which a runtime window rule (`hl.window_rule`, registered once per compositor session) floats, pins, centers and sizes at map time; dispatchers repeat the placement if the rule is unavailable. The target is identified by window address, PID and process start time; paste writes with wl-copy, focuses the target and sends Ctrl+V (Ctrl+Shift+V for terminal classes). Unsupported generic Wayland sessions copy the selected content and explain the manual paste fallback; `clipboard --overlay` opens the picker from any compositor shortcut. Main-window state is restored after picker dismissal when the picker was opened from it. Launch-at-login (`--background`) keeps the window unmapped in the native runner.

Shortcut settings are configurable. Detectable conflicts become actionable errors. Hyprland runtime binding cleanup is scoped to bindings owned by the app; it does not rewrite persistent compositor configuration.

The Hyprland adapter reads the active configuration provider. Lua sessions use
hyprctl eval with hl.bind and owned keybind handles; focus/paste use hl.dsp and
check their returned results. Legacy sessions retain keyword/dispatch support.
The implementation follows the [current Hyprland API](https://wiki.hypr.land/configuring/core/advanced-configuration/using-hyprctl/).
Restart an older running app after rebuilding to load this change. No compositor
reload or persistent shortcut entry is needed.

Tray/menu Open and Quit actions control the existing engine. Close hides only when background mode and an accessible host are available. Login startup points to a stable installed executable, never a build sandbox or temporary SDK.

## Tests

Native Linux tests cover clipboard formats, sensitive flags, local file URI filtering, process timeouts and safe startup escaping. scripts/test-native-linux.sh performs real secure pairing, history receipt and GTK target paste in Hyprland. Flutter tests cover picker keyboard navigation and compact layouts.

Do not assume a Linux check validates Windows/macOS permissions or focus behavior. See platform-limitations.md.
