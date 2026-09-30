# Arcade Clipboard implementation contract

Initial target: real paired text synchronization and desktop mesh picker. Flutter owns product UI; Rust owns identity, trust, pairing, cryptography, durable history and synchronization. Platform adapters own capture, shortcut, focus and paste. No production mocks. Unsupported actions return actionable errors.

## Ownership
- Root: workspace manifests, shared interfaces, integration, docs, release scripts.
- Core worker: `core/rust/**` (Rust library crate `arcade_core`).
- UI worker: `apps/flutter_app/lib/**`, `test/**`, `pubspec.yaml`, analysis options.
- Desktop worker: `platform/desktop/**` and Dart platform adapter file `apps/flutter_app/lib/platform/desktop_adapter.dart`.
- Relay worker: `services/relay/**` (crate `arcade_relay`).
- Mobile worker: `platform/ios/**`, `platform/android/**`, mobile integration docs.
- Toolchain worker: workspace-local SDK installation, generated Flutter runners, bridge code generation/build wiring, CI/tool scripts. Coordinate before editing others' files.

## Data/API boundary
Use flutter_rust_bridge 2.13.0, exact matching Dart and Rust versions. JSON at the narrow initial application API boundary is acceptable; do not write custom FFI. Core `api` module exposes `pub async fn call(request: String) -> Result<String, String>`; one JSON request contains `op` and arguments. Responses are JSON objects. All potentially blocking operations must stay off UI thread.

Operations: `initialize {data_dir,device_name}`; `status`; `create_mesh {device_name}`; `create_invite`; `join {invite,device_name}`; `confirm_pairing {session_id,accept}`; `history {query,limit}`; `capture {text}`; `devices`; `revoke {device_id}`; `delete {id}`; `pin {id,pinned}`; `settings {values?}`; `shutdown`. Core worker may refine arguments with an early interface note to all agents/root. UI must display genuine pending/error states.

History item: `id`, `origin_device`, `source_name`, `created_at` (Unix milliseconds), `text`, `kind` (`text`/`url`), `pinned`. status: initialized, mesh_id nullable, device_id, device_name, paused, connection and diagnostic detail. History always comes from Rust storage, never demo fixtures. Capture pause enforced in core.

Desktop adapter: async initialize callbacks `onTextCaptured(String)`, `onOverlayRequested()`; capability reporting; show/hide overlay; pasteText(String); configureShortcut(String). Capture suppression must prevent mesh paste from becoming a newly originated clip. Must not claim portable Wayland focus injection: capability gate unsupported compositors, provide explicit copy fallback. Do not install privileged injection daemons.

## Protocol/security direction
Version 1, UUID identities/items, bounded JSON messages, SQLite migrations, persistent deduplication, origin and logical ordering, expiry. Use vetted Noise implementation (snow) for end-to-end authenticated sessions. QR contains short-lived bootstrap session, ephemeral authorization and public information only. Human verification must gate trust. No long-term private keys in QR or plaintext config. Keychain storage with explicit secure failure when unavailable. Never silently downgrade. Prefer pairwise encryption to avoid premature group cryptography; trust membership/removal must propagate and future transmissions exclude revoked devices.

Relay is a bounded opaque store-and-forward service. It must not possess client decryption keys. Decide exact wire route contract with core before implementation. LAN and relay are transport paths for the same authenticated protocol. No TLS-only encryption claim. Relay URLs are deployment config, not guessed public services.

## Completion evidence
Format/lint/tests/build executed where toolchains allow. Native platform behavior requires real OS testing; do not call untested source a working port. Keep architecture and limitations documents factual. No misleading release claims.
