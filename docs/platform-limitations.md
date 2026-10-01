# Platform behavior and limits

| Platform | Implemented integration | Verification |
| --- | --- | --- |
| Linux / Hyprland | MIME capture, Lua/legacy runtime shortcut, target identity/focus, Enter paste, tray/startup | Local release builds and earlier native checks; full GUI paste acceptance incomplete; latest Lua fix not live-tested |
| Linux / X11 | GTK clipboard, keybinder shortcut, X11 focus/paste helper | Source/native compilation; target-session acceptance needed |
| Other Wayland | Automatic capture where the compositor supports data-control (KDE, Sway, …; needs wl-clipboard), picker via `clipboard --overlay` bound to a system shortcut, copy fallback | No in-app global shortcut or cross-app paste; GNOME lacks data-control, so no background capture |
| iPhone/iPad | Share extension, text clipboard keyboard, App Group handoff, Bonjour, Keychain core | Xcode/real-device acceptance needed; unsigned IPA workflow supplied |
| Android | Share target, text IME, image copy/export provider, Keystore identities | APK cross-build checked; real-device acceptance needed |
| Windows | Clipboard formats, global shortcut, native focus/paste, tray and login startup | Windows build/device acceptance needed |
| macOS | Pasteboard, shortcut, focus/paste, menu bar and SMAppService | macOS build/device acceptance needed |

## Desktop

Remote receipt never changes the active clipboard. Explicit copy/paste does. The selected content stays on the clipboard after paste because blind timed restoration can break applications that consume clipboard data asynchronously.

Hyprland bindings are installed for the current session and removed by the app. No generated temporary path is written to compositor configuration. Automatic paste requires a still-valid remembered target; failed focus/paste exposes copy fallback.

Background mode needs a working tray/menu host. If no host is available, the app disables hide-to-background behavior to keep the window reachable.

## iOS

The main app cannot promise continuous background networking. A share is saved with iOS Data Protection, then imported/synchronized when the app resumes. Open the app to refresh keyboard history.

The keyboard is a secondary text clipboard browser, not a replacement typing keyboard. It reads shared cached text, normally without Full Access (offered only as a fallback if iOS denies shared-storage reads), offers internal search keys/pins and the standard globe switch. Secure fields and apps that disallow third-party keyboards use system behavior. Image insertion is not universal; copy/share are available in the main app.

The main app and both extensions must be signed with a matching valid App Group entitlement. A signer that strips capabilities may install the UI but cannot provide shared extension storage.

## Payloads and hosting

Text is bounded to 32 KiB; clips to 16 MiB aggregate/32 representations. Folder transfer, unlimited files and byte-offset resume are not implemented. The client retains bounded encrypted history; the relay forwards only between live connected devices.

Different-network synchronization needs a reachable WSS relay. A domain alone does not run the service. See relay-deployment.md.
