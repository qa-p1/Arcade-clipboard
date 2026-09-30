# Protocol v1 — text development slice

The implemented codec uses bounded JSON over a four-byte big-endian length-prefixed stream. Noise ciphertext frames are at most 65,535 bytes, including the authentication tag. Serialized JSON size is checked because UTF-8 text can expand when escaped. Unknown message variants fail the connection; unknown JSON fields are ignored. Current items support text and URLs only. Rich payloads and capability negotiation are not implemented.

## Trust and topology

The device that creates a mesh is its authority. It signs Ed25519 member certificates and revocation records. Each device generates its own Curve25519 Noise identity and encrypted-local-database key. The current runtime uses an authority-centered topology: members connect to the authority; the authority forwards accepted clips to active members. Members can retain local work while the authority is unavailable. There is no implemented mDNS discovery or client relay fallback.

An invitation carries versioned, short-lived pairing authorization, mesh/session identifiers, public identity information, and the authority endpoint; it does not carry a long-term private identity key. Pairing uses `Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s`; later sessions use `Noise_XX_25519_ChaChaPoly_BLAKE2s` and validate the peer identity against stored membership. The joining device pins the authority public key from the invitation. A six-digit verification code is derived from the handshake transcript, and both sides must confirm before pairing commits.

The initial bootstrap identifies an invitation before Noise begins; it is routing information, not authentication. Expiry, single-use handling, key pinning, protocol version, and user confirmation are trust boundaries implemented by the clients. See [security review](security-review.md) for remaining review risks.

## Items and convergence

A v1 item contains a protocol version, UUID, origin device, sender sequence, source name, creation and expiry times, text, kind, and content hash. IDs and origin remain stable across hops. The content hash is BLAKE3 over the exact UTF-8 text and travels only inside the encrypted session. At rest, the stored hash is keyed to reduce guessed-content lookup.

SQLite stores encrypted payloads, deduplication records, and deletion tombstones. Item lifetime is capped at 30 days and future timestamp skew at five minutes. The store has bounded history, seen-item, deletion, and revocation records. Receiving an item adds it to mesh history; it does not write to the operating system clipboard.

## Not implemented or not verified

This protocol slice has no client relay path, mDNS discovery, image/file transfer, pin synchronization, or content capability negotiation. The standalone relay forwards opaque WebSocket frames but is not part of this client's sync path. The implementation and test sources are not equivalent to a successful build or acceptance run; see [development](development.md) and [acceptance](acceptance.md).

References: [Noise Protocol Framework](https://noiseprotocol.org/noise.html), [snow TransportState](https://docs.rs/snow/0.10.0/snow/struct.TransportState.html), [Ed25519 verification](https://docs.rs/ed25519-dalek/2.2.0/ed25519_dalek/struct.VerifyingKey.html).
