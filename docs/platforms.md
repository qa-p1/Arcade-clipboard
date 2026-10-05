# Platforms

The Rust core, the encryption and the sync protocol are the same everywhere. What differs between platforms is how the app reads and writes the clipboard, how the picker is opened, and whether it can paste into another app.

| | Automatic capture | Global shortcut | Paste into previous app | Background sync | Tested on |
| --- | --- | --- | --- | --- | --- |
| Linux, Hyprland | Yes | Yes | Yes | Yes | Real hardware, end to end |
| Linux, X11 | Yes | Yes | Yes, with `xdotool` | Yes | Build only |
| Linux, other Wayland | With data-control (not GNOME) | Bind `clipboard --overlay` | No, copies for Ctrl+V | Yes | Build only |
| iPhone, iPad | No (iOS does not allow it) | Share sheet and keyboard | Keyboard inserts text | Only while the app is open | Not yet run on a device |
| Android | No | Share target and keyboard | Keyboard inserts text | While the app runs | Build only |
| Windows | Yes | Yes | Yes | Yes | Not built |
| macOS | Yes | Yes | Yes, needs Accessibility | Yes | Not built |

"Build only" means the code compiles in CI or locally but has not been exercised on that system. "Not built" means the native code exists but has never been compiled.

## Linux

See [Linux](linux.md).

## Other Arcade apps (Arcade Link)

On Linux, Windows and macOS, Clipboard works with the other Arcade apps through [Arcade Link](arcade-link.md): "Send to my devices" in Lens, Look and Box, and choosing a clip from history in Box and Wheel. iPhone, iPad and Android are not Link participants (apps there can't reach each other over local sockets, and background work is limited). They still benefit: content a desktop app sends with "Send to my devices" arrives in their history like any other clip.

## iPhone and iPad

See [iPhone](ios.md). In short:

- iOS does not let apps read the clipboard in the background, so copies on the iPhone are not added automatically. Use the share sheet, or add a clip in the app.
- iOS suspends the app when it leaves the screen. Sync resumes as soon as you open it, and other devices hold clips until then.
- The keyboard inserts text clips only. Images and files can be copied or shared from the app.

## Android

The Android runner includes:

- **Share target.** Text, links, images and files, up to 16 MB per share.
- **Clipboard keyboard** (an input method). Inserts text clips through the standard input connection.
- **Keystore-backed identity.** The device's private keys are encrypted with an Android Keystore key, which never leaves secure hardware where available.
- **File export.** Saving or sharing a file grants access only to the app you choose.

Shares and the keyboard's clip list are passed between the app and its components through files encrypted with the Keystore key. Android allows the app to keep running while the system has the resources, so sync continues in the background more reliably than on iOS, but it is not guaranteed.

To build: install the Android SDK and NDK plus the Rust Android targets, run `python3 scripts/build-android-core.py`, then `flutter build apk` in `apps/flutter_app`.

## Windows

The Windows plugin uses the native clipboard listener for capture and supports text, HTML, RTF, images and files. The shortcut defaults to **Ctrl+Alt+V**. Before pasting, the app checks that the remembered window still belongs to the same process, then restores focus and sends Ctrl+V. It includes a tray icon and launch at login. Build with `flutter build windows` on Windows; CMake compiles and bundles the Rust library.

## macOS

The macOS plugin watches the pasteboard for changes while capture is on. The shortcut defaults to **Cmd+Shift+V**. Pasting into another app requires Accessibility permission, which **Settings → Allow automatic paste** requests; without it, the chosen clip is copied and you press Cmd+V. The app lives in the menu bar and uses `SMAppService` for launch at login. Build with `flutter build macos --release`, then `bash scripts/build-macos-core.sh`.

## Limits on every platform

- Text clips are limited to 32 KiB, and a clip with images or files to 16 MiB and 32 parts.
- Folders cannot be shared.
- An interrupted transfer restarts from the beginning; there is no partial resume.
- History is limited by **Keep history** (1 hour to 30 days, default 24 hours) and **History limit** (500 to 5,000 clips, default 500). Pinned clips do not expire but count toward the limit.
- A device removed from the mesh keeps the clips it already received. Removal stops all future sync with it.
- Sync between different networks needs a [relay](relay-deployment.md) that both devices can reach.
