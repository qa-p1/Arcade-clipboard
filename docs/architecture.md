# Architecture

Flutter owns onboarding, history, devices, settings, pairing and the compact picker. Rust owns device identity, membership, cryptography, synchronization, discovery and durable history. Native adapters implement clipboard formats, focus/paste, tray/startup and mobile extensions.

| Path | Responsibility |
| --- | --- |
| apps/flutter_app | Shared UI/controller and generated Flutter Rust Bridge bindings |
| core/rust | Noise sessions, certificates, origin signatures, LAN/relay transport, encrypted SQLite history |
| platform/desktop | Small Windows/macOS/Linux adapters and bounded Linux helpers |
| platform/ios | Share and Keyboard extensions, App Group handoff, system Bonjour |
| platform/android | Share activity, IME, encrypted handoff, Keystore identity provider |
| services/relay | Bounded opaque WebSocket rendezvous and forwarding |
| tests | Real process driver, core integration tests and native paste target |

## Mesh and data flow

The creator signs membership and revocation records. Every device has its own X25519 identity and item-signing key. All trusted devices listen and may connect directly; synchronization does not depend on the creator remaining online.

Desktop capture is on by default (Private mode pauses it). On Wayland a bundled supervisor runs `wl-paste --watch` and only signals changes; Dart reads the selection with `wl-paste` and writes with `wl-copy`, because the Dart VM reaps child processes and GLib's GSubprocess cannot be used alongside it. The supervisor exits when the app's stdin pipe closes, so a killed app never leaves watchers behind. Re-capturing existing content moves it to the top (old copies are deleted mesh-wide); the watcher's initial event at startup only adds content that is not already in history. Both devices of a pair dial each other (the hello carries the listening port); simultaneous dials converge on the connection dialed by the smaller device ID; unreachable peers are retried with 2–60 s backoff. Explicit app additions and mobile handoff submit compatible representations to Rust. Rust validates and signs the item, encrypts local storage, and sends it over authenticated Noise. Receivers validate origin membership/signature and stable item identity before storing. Remote receipt has no OS clipboard write path.

mDNS supplies candidate addresses, never authorization. iOS uses system Bonjour; other targets use mdns-sd. Pairwise relay routes derive from a secret shared capability and carry the same Noise protocol over WebSockets. LAN is preferred and retried after relay takeover.

History catch-up snapshots IDs and loads one payload at a time. Large items use bounded chunks and backpressure. Search/display read a small encrypted preview rather than decrypting all file contents. Deletion tombstones prevent reappearance; signed Lamport pin updates converge after disconnection.

## Platform boundary

The desktop picker remembers the target, hides before selection paste, restores focus and invokes the platform paste mechanism. Unsupported desktop sessions expose a copy fallback.

Mobile share/keyboard storage is a protected handoff/cache, not a second synchronization implementation. iOS can suspend the main app; pending shares are imported on resume and the keyboard uses already-cached text. See platform-limitations.md.
