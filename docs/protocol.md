# Protocol v1

Messages are bounded JSON over a four-byte big-endian length-prefixed byte stream. Noise ciphertext frames are limited to 65,535 bytes including the authentication tag. TCP and relay WebSockets share the authenticated session codec.

## Trust

Pairing uses Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s with a random short-lived authorization token. Paired sessions use Noise_XX_25519_ChaChaPoly_BLAKE2s and validate the Noise static identity against an owner-signed certificate. Both pairing participants compare a six-digit transcript-bound verification code and approve before commit. Tokens expire after 120 seconds and are consumed.

Certificates bind mesh/device ID, static public key, item-signing public key, name, platform and capabilities. The creator signs membership and revocations with Ed25519. Signed origin provenance covers the canonical item, including representations and file names. A trusted peer may forward another member's retained item without impersonating its origin.

## Items

Items carry protocol version, UUID, origin device, sender sequence, timestamps, expiry, type, text, representations, content hash and origin signature. A representation contains MIME type, base64 data and an optional safe file name. Plain text is limited to 32 KiB; aggregate decoded content to 16 MiB and 32 representations.

Supported types are text, URL, rich text, image, file and files. HTML/RTF and compatible plain text can coexist. PNG/JPEG dimension and encoded-data bounds are checked. Files are transferred as content, not remote paths.

Payloads beyond one frame use 24 KiB chunks. Reconnect restarts a retained item's transfer; byte-offset resumption is not implemented. IDs and hashes stay stable across forwarding, resend and catch-up. Replays with different content under one ID fail.

## Convergence and storage

SQLite stores encrypted payloads and encrypted history previews with XChaCha20-Poly1305. Authenticated associated data binds item headers; stored content lookup tags are keyed. Schema migrations are transactional. Device/routing/timestamp metadata is not all encrypted.

Signed pin preferences use a Lamport revision and actor-ID tie break. Deleted-item tombstones and seen IDs prevent synchronization loops and deleted-history resurrection. Retention defaults to 24 hours and 500 items; settings bound history to 10,000. Pinned content survives time expiry until unpinned, but remains subject to the count limit.

Membership/revocation information and pin preferences precede history catch-up. Connection checks and heartbeat timeouts support reconnect without re-pairing. Unknown JSON fields are ignored; unknown message variants and unsupported protocol versions fail the connection.

## Relay

The relay receives opaque frames only. Pair routes and bearer tickets derive separately from a contributory pairwise X25519 secret and context. Public device identifiers do not reveal a usable route. Noise still authenticates the peer after routing.

The relay has bounded connections, frames and queues, short rendezvous windows and an evictable idle route cache. It retains no offline clipboard archive. Trusted devices retain encrypted history for delivery on reconnect.

References: [Noise](https://noiseprotocol.org/noise.html), [snow](https://docs.rs/snow/0.10.0/snow/), [Ed25519](https://docs.rs/ed25519-dalek/2.2.0/ed25519_dalek/).
