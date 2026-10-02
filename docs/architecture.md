# Architecture

Arcade Clipboard has three layers:

```
┌───────────────────────────── Flutter app (Dart) ─────────────────────────────┐
│  UI: onboarding, history, picker, devices, settings     AppController        │
│  DesktopAdapter (capture, shortcut, picker, paste)     MobileShareBridge     │
└───────────────┬─────────────────────────────────────────────┬────────────────┘
                │ one JSON call: api::call                    │ method channels
┌───────────────▼──────────────────┐        ┌─────────────────▼────────────────┐
│ Rust core (core/rust)            │        │ Native code (platform/)          │
│ identity, pairing, membership,   │        │ Linux GTK plugin + Wayland helper│
│ encrypted SQLite history,        │        │ iOS share/keyboard extensions    │
│ Noise sessions, LAN + relay sync │        │ Android share/IME, Windows, macOS│
└───────────────┬──────────────────┘        └──────────────────────────────────┘
                │ Noise over TCP, or over WebSocket through the relay
                ▼
          other devices
```

Rust owns everything that must be correct across devices: identities, membership, encryption, storage and sync. Dart owns the user interface and decides what to capture and when to paste. Native code does only what needs platform APIs. It holds no history of its own and makes no trust decisions.

## Repository layout

| Path | Contents |
| --- | --- |
| `apps/flutter_app` | Flutter app: UI (`lib/app.dart`, `lib/clipboard_widgets.dart`), `AppController`, platform adapters, generated bridge bindings, platform runners |
| `core/rust` | The core library: `core.rs` (operations, connections), `store.rs` (SQLite), `transport.rs` (sessions), `crypto.rs`, `payload.rs`, `discovery.rs` (mDNS), `secret.rs` (key storage) |
| `services/relay` | The relay server |
| `platform/desktop/arcade_desktop_bridge` | Flutter plugin for Linux, Windows and macOS clipboard, focus, tray and login items |
| `platform/ios` | Swift sources for the iOS host channel, share extension and keyboard extension |
| `platform/android` | Kotlin share activity, input method and Keystore identity provider |
| `tests` | Multi-process test driver, Secret Service harness, native paste target |
| `scripts` | Build, packaging and setup scripts |

## The Flutter–Rust boundary

The app calls Rust through [flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/) with a single function, `api::call`, which takes a JSON request (`{"op": "capture", ...}`) and returns a JSON object. Keeping the boundary to one function keeps the generated bindings small and the API easy to evolve. `CoreApi` in `lib/services/core_api.dart` wraps it.

The main operations are:

| Area | Operations |
| --- | --- |
| Lifecycle | `initialize`, `status`, `wait_for_change`, `resume`, `shutdown` |
| Pairing | `create_mesh`, `create_invite`, `join`, `confirm_pairing` |
| History | `history`, `payload`, `capture`, `resend`, `pin`, `delete`, `clear_history` |
| Devices | `devices`, `revoke` |
| Settings | `settings` |
| Mobile discovery | `discovery_config`, `discovery_candidates` |

`wait_for_change` is a long poll that returns when the history, device list or connection state changes. The controller keeps one outstanding call, so remote clips appear without polling.

How the Rust library is loaded:

| Platform | Library |
| --- | --- |
| Linux | `lib/libarcade_core.so` next to the executable |
| Windows | `arcade_core.dll` next to the executable |
| macOS | `Frameworks/libarcade_core.dylib` |
| Android | `libarcade_core.so` from the APK |
| iOS | Static library linked into the app; symbols are looked up in the running process |

`ARCADE_CORE_LIBRARY` overrides the path during development.

## Desktop capture

Capture runs in `DesktopAdapter` (`lib/platform/desktop_adapter.dart`):

1. **Change notification.** On Wayland, the bundled `arcade_clipboard_wl_capture` helper supervises `wl-paste --watch` and writes a line for each change. On X11 and the other desktop platforms, the native plugin listens for clipboard ownership changes.
2. **Read.** On Wayland, Dart runs `wl-paste --list-types`, then reads up to one candidate per canonical type: text, HTML, PNG, JPEG and file URIs. Content flagged as sensitive by password managers is dropped.
3. **Self-write check.** Anything the app wrote to the clipboard in the last three seconds, for example a clip it just pasted, is ignored.
4. **Store.** `AppController` turns the formats into representations and sends a `capture` request. Plain text takes a fast path with no image or file processing.

Wayland reads and writes run in Dart rather than in the GTK plugin. The Dart VM reaps every child process once it has started any, which breaks GLib's subprocess handling, so a read would intermittently report no clipboard data. The helper process is the only native piece. It exits when its standard input closes, which happens when the app exits for any reason, so it cannot outlive the app.

### Deduplication

The core compares a keyed hash of the content with existing clips:

- If the content matches the newest clip or a pinned clip, nothing changes.
- If it matches an older clip, that clip is deleted on every device and the content is added again as a new clip, so it moves to the top everywhere.
- The capture of the clipboard's existing content at app start uses `only_if_new`, which only adds content that is not already in history.

## Picker and paste

The shortcut handler remembers the focused window before showing the picker. On Hyprland it stores the window address, process ID and process start time, so a reused PID cannot redirect a paste. After a clip is chosen, the adapter hides the picker, writes the clip to the clipboard, verifies the target still exists, focuses it and sends the paste shortcut. Ctrl+Shift+V is used for terminals. If any step fails, the clip is left on the clipboard and the app shows a notice. [Linux](linux.md) has the compositor-specific details.

## Identity and storage

Each device has an X25519 key for Noise sessions and an Ed25519 key for signing the clips it creates. These keys, together with the database key, are stored in the platform credential store: Secret Service on Linux, Keychain on Apple platforms, Credential Manager on Windows, and a Keystore-encrypted file on Android. A profile whose stored identity is missing or damaged fails to open instead of silently creating a new one.

History lives in SQLite. Payloads and the small previews used for the list are encrypted with XChaCha20-Poly1305, and each record's header is bound as associated data. A profile lock file ensures only one process opens a profile at a time.

## Mesh membership

The device that creates the mesh is its owner. It signs a membership certificate for every device it admits, covering the device's keys, name and platform, and signs revocations when it removes one. Every device stores the certificates and checks them on each connection. Members sync with each other directly, so the owner does not need to be online.

Pairing is described in [Protocol](protocol.md#pairing).

## Connections

Every device listens on a TCP port, chosen once and reused after restarts so that announcements stay valid.

- **Discovery.** Desktop and Android announce and browse `_arcade-clip._tcp` with mDNS. On iOS, the Swift host uses Bonjour (`NetService`), which is the only option allowed without a special entitlement, and passes the addresses it finds to the core through `discovery_candidates`. Discovered addresses are only hints: a connection is trusted only after its Noise handshake proves a key that matches a valid, unrevoked certificate.
- **Dialing.** Both devices of a pair dial each other. Each hello carries the sender's listening port, so a device that was reached first can call back. Unreachable peers are retried with exponential backoff from 2 up to 60 seconds, and the backoff resets when a device's address changes.
- **Duplicate connections.** When two devices dial each other at the same time, both connections can succeed. Within ten seconds of the first, both sides keep the connection whose Noise handshake hash is smaller. Both compute the same hash, so they converge on the same connection.
- **Liveness.** Each connection sends a heartbeat every 15 seconds. A connection that cannot send one is closed and redialed.
- **Relay.** If a relay is configured, devices also meet on a route derived from their pairwise shared secret. The relay forwards opaque Noise frames. When a direct LAN connection becomes available, it replaces the relay connection.
- **Resume.** Mobile operating systems can close sockets while the app is suspended. The `resume` operation, called when the app returns to the foreground, drops stale connections, rebinds the listener if necessary and redials immediately.

## Sync

When a clip is captured, the core signs it with the device's Ed25519 key, stores it and sends it to every connected device. Receivers check that the origin is a current member and that the signature covers the exact content before storing it. A device may forward clips it received from others, so a clip reaches the whole mesh even when two members are never connected directly.

On every new connection, the devices exchange membership updates and pin states first, then a list of clip IDs, then the clips the other side is missing. Payloads are loaded one at a time and sent in 24 KiB chunks with backpressure, so a large history does not have to fit in memory.

- **Pins** are per-clip signed records with a Lamport counter. The higher counter wins, and ties are broken by device ID, so every device converges.
- **Deletions** leave a tombstone that stops the clip from coming back from a device that missed the deletion.
- **Retention** is applied on each device independently. Pinned clips are kept until unpinned.

A received clip is written to history only. The core has no path that writes a received clip to the operating system clipboard.

## Mobile handoff

Mobile extensions run in separate processes with tight memory limits and no access to the core. They exchange data with the app through files:

- **Share inbox.** The share extension writes each share as a JSON file in the shared container. The app reads the inbox on start and resume, captures each entry through the core, and deletes the file only after the capture succeeds.
- **Keyboard cache.** Whenever history changes, the app writes up to 30 recent text clips to a cache file. The keyboard reads this file and never writes anything.

On iOS the files are in the App Group container with complete data protection. On Android they are encrypted with a Keystore key.
