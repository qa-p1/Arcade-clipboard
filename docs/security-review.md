# Security review status

Review date: 2026-09-30  
Scope: current checked-in Rust core and storage, Flutter/native boundaries, mobile handoff source, and standalone relay.  
Status: **Open; not a release sign-off.** This is a source-level checkpoint review, not an independent cryptographic audit. No tests, native builds, or emulator checks were run for this publishing checkpoint. Do not put sensitive clipboard content into this build.

## Security design present in source

- The direct client transport uses the Noise framework with authenticated device identities and encrypted messages. Pairing uses a temporary authorization secret; long-term private identity keys are not encoded in the invitation.
- The creator device signs membership certificates and revocation records. Pairing requires user confirmation on both sides and displays a short verification code.
- Rust stores clipboard payloads encrypted in SQLite with XChaCha20-Poly1305. Identity and database keys are loaded from the OS credential store on supported desktop targets; there is no plaintext fallback. The relay is a separate opaque-frame service, not a trusted plaintext store.
- Stable item IDs, origin device, deduplication state, expiry, and tombstones support loop prevention and bounded history.
- Android and iOS have separate protected share/keyboard handoff stores. That protection does not substitute for the Rust mesh identity store or prove end-to-end delivery.

These are source observations, not claims of completed security testing. SQLite routing metadata is not all encrypted, and information such as device identity, timestamps, item sizes, and connectivity may remain observable locally or to a direct peer/relay as required by the implementation.

## Open release blockers

1. **Android mesh identity storage is missing.** `core/rust/src/secret.rs` fails closed for Android. The Android Keystore key in `MobileSharedStore.kt` protects only extension handoff data, not the Rust identity or database key. Android cannot initialize a mesh until the core's secure store is integrated and device-tested.
2. **iOS native setup is unverified.** No iOS runner has been generated or built. The setup script's `new_copy_files_build_phase` call needs correction/validation against the selected `xcodeproj` API before target embedding can be relied on.
3. **Hyprland capture is blocked by MIME detection.** The Linux helper requires `CLIPBOARD_TYPE` to be present and plain text. Current `wl-paste --watch` behavior does not reliably export it, so clipboard monitoring cannot be claimed to work there.
4. **Pair-commit storage is not atomic.** `apply_pair_commit` writes peer records and mesh metadata through separate SQLite operations. A process failure mid-commit can leave partial local join state; make the membership and profile update transactional before release.
5. **Core API shutdown can race in-flight operations.** `api::call` clones the current `Arc<Core>` before awaiting a request, while shutdown removes and shuts down that core. Define and enforce a lifecycle boundary before relying on concurrent app restart/shutdown behavior.
6. **Remote recovery is incomplete.** The client has no relay fallback, mDNS discovery, or demonstrated offline queue delivery. The standalone relay is not wired into the sync client. CGNAT/reconnect behavior is not a release-ready claim.
7. **No current-tree verification evidence is recorded.** Test source exists, including Rust unit/integration and process-smoke files, but this checkpoint did not execute it. Pairing replay/rejection, live revocation, malformed-message behavior, key-store behavior, and native extension boundaries need explicit security review and evidence.

## Required before a security sign-off

Use [security-review-checklist.md](security-review-checklist.md) and [acceptance.md](acceptance.md) on the exact release candidate. Review pairing expiry/replay and SAS binding, certificate and sender authorization, revocation freshness on active/reconnected peers, persistent-key backup/restore and loss, encrypted database metadata, relay routing privacy and bounds, clipboard log redaction, extension entitlements and handoff validation, and each platform's secure-store behavior. Run meaningful automated checks and real-device acceptance only on the release candidate and record exact commit IDs and results.
