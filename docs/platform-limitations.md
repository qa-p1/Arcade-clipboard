# Platform limitations and release gates

No platform in this checkout is release-ready. Source code, a successful native build, and observed behavior on a real device are separate evidence levels. Flutter runners and bridge bindings are absent, and no native or emulator acceptance was performed for this publishing checkpoint.

| Platform | Source present | Current blocker / evidence still needed |
| --- | --- | --- |
| Linux X11 | Flutter desktop adapter, native bridge, clipboard watcher, shortcut, remembered target, and `xdotool` paste path | Generate the Flutter runner and bridge; verify copy capture, shortcut conflict/rebinding, focus restoration, paste, and resume after sleep on X11. |
| Hyprland / Wayland | Compositor binding, target-window checks, and an opt-in `wl-paste --watch` helper | The helper accepts events only when `CLIPBOARD_TYPE` is set to plain text. The documented `wl-paste` 2.2/2.3 watch path does not reliably provide that variable, so automatic capture is currently a known blocker. Verify against the actual Hyprland/`wl-clipboard` versions before claiming capture works. |
| Other Wayland compositors | Capability-gated fallback | Generic Wayland does not grant unrestricted global shortcuts, clipboard monitoring, focus stealing, or synthetic paste. Keep the explicit copy fallback; do not promise automatic capture/paste. |
| macOS | AppKit bridge source for focus restoration and Accessibility-gated paste | Generate runner and bindings; build/sign and verify permission grant/denial, previous-app focus, paste, and lifecycle on macOS. |
| Windows | Native bridge source for window revalidation and paste input | Generate runner and bindings; build with MSVC and verify window focus, UIPI/elevated-window behavior, clipboard capture, and shortcut conflicts on Windows. |
| Android | Share Target, text IME, and encrypted handoff source | Rust `SystemSecretStore` intentionally errors on Android; identity and DB key are not backed by Android Keystore. Mesh initialization is blocked until secure storage is wired. Runner/channel registration and physical-device checks are also outstanding. |
| iPhone / iPad | Share Extension, custom text keyboard, App Group store, and host method channel source | No generated runner or signed build. `scripts/setup-ios.rb` calls an `xcodeproj` copy-phase API with an unverified/incompatible argument list; fix and validate the installer before relying on it. Verify signing, entitlements, share queue recovery, keyboard insertion, and pairing on devices. |

The desktop picker intentionally places a selected item into the OS clipboard before triggering paste. It does not attempt timed restoration of the old clipboard because applications may read asynchronously. A failed paste should leave the selected value available for the copy fallback. Receiving remote clips never changes the active OS clipboard.

Mobile keyboards are clipboard browsers, not replacements for system typing keyboards. Secure fields and applications that prohibit third-party keyboards retain system behavior. Universal image insertion is not promised. iOS sharing queues locally and requires the host app to synchronize; it is not background delivery. Android's protected handoff key is separate from the unimplemented Rust identity store.

See [desktop integration](desktop-integration.md), [mobile integration](mobile-integration.md), and [toolchain blocker](verification/toolchain-blocker.md) for details.
