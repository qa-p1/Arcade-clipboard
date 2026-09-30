# Mobile integration status

Native iOS and Android integration source is present, but neither mobile application is currently buildable from this checkout or validated on a device. Flutter platform runners and Rust bridge bindings are absent. Do not treat the extension source or setup scripts as a working mobile port.

## iOS / iPadOS

The source under `platform/ios` includes a Share Extension, a custom text clipboard keyboard, an App Group handoff store, entitlements, and a host method channel. The share path queues text/URLs locally; it does not establish that the item has reached another device. The keyboard reads a bounded snapshot and inserts only a user-selected text item. `RequestsOpenAccess` is false, so the source does not request Full Access. Secure fields or applications that reject third-party keyboards use system behavior.

A native Mac workflow will need Xcode, Flutter, Rust for `aarch64-apple-ios`, CocoaPods, Ruby, and a compatible `xcodeproj` gem. First generate the missing Flutter runner and bindings in a normal development environment, then inspect and fix `scripts/setup-ios.rb` before running it: its `new_copy_files_build_phase` invocation has not been reconciled with the installed `xcodeproj` API. Build and sign all three targets (Runner, Share Extension, Keyboard Extension), register the App Group for the signing team, and validate on an iPhone/iPad. The checked-in script and entitlements are not evidence that this process succeeds.

Device acceptance still needs to cover App Group access, URL/text share activation, recovery after host termination, keyboard enablement and insertion, paused/no-mesh behavior, queue acknowledgement, pairing, and synchronization. No simulator or device tests were run for this checkpoint.

## Android

The source under `platform/android` includes a Share Target, text IME, method-channel adapter, and Android Keystore-protected extension handoff. The Rust core's `SystemSecretStore` currently fails closed on Android, so it cannot create/load the mesh identity and encrypted database key. This blocks mesh initialization until the secure identity store is integrated. The Android runner and Flutter channel registration are also not generated or verified.

After those blockers are fixed, validate sharing, IME activation/insertion, secure-field fallback, process death/recovery, and mesh synchronization on a physical Android device. No Android emulator or device tests were run for this checkpoint.
