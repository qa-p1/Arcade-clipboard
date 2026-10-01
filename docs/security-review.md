# Security review record

Updated 2026-10-02. Reviewed boundaries: pairing, membership and revocation, origin signatures, encrypted local storage, relay routing, native providers, mobile handoff and keyboard access.

## Resolved findings

| Finding | Change |
| --- | --- |
| Public-ID relay route could be reserved by an observer | Route and ticket derive independently from the secret pairwise X25519 capability |
| Unauthenticated idle route reservations could fill the cache | Short idle retention and oldest-idle eviction; active/global connection caps stay bounded |
| Reconnect collected entire binary history in memory | ID snapshot, one-payload loading and lazy chunk production |
| History refresh decrypted all binary contents | Small encrypted, header-authenticated preview cache |
| Pair setup could partially commit | Transactional membership/profile writes |
| API initialize/shutdown raced requests | Read/write lifecycle boundary |
| Android Rust identity store was absent | JNI provider backed by Android Keystore AES-GCM and AtomicFile |
| iOS raw mDNS required a restricted entitlement | Native Bonjour adapter and declared service name |
| Extension bundle metadata/version wiring was incomplete | Explicit metadata and matching Flutter build versions |
| Hyprland clipboard MIME detection was brittle | Bounded native reads and MIME-aware watcher |
| iOS search had no typing surface | Internal search keys; host input remains untouched |

## Verified here

Rust unit/integration and real WebSocket tests pass, with strict Clippy. Flutter analysis and controller/widget/visual tests pass. Linux debug/release builds have completed. The native acceptance test uses two real secure profiles, the actual Flutter/Rust boundary and a separate GTK paste target; its recorded outcome is in verification/checkpoint.md.

## Remaining target-platform checks

An iPhone needs a signed build with the same App Group for the app and both extensions. Local Linux cannot execute an Xcode build or an iPhone extension. Windows/macOS build and focus/input acceptance also require those systems.

iOS can suspend networking; shared inbox import and keyboard-cache refresh occur when the main app runs. The relay stores no offline archive. Large transfers have a 16 MiB aggregate bound and restart after interruption.

Do not interpret old publishing-checkpoint reports as current source status. Review [security](security.md), [acceptance](acceptance.md) and the exact Actions build result for release evidence.
