# Security

Clipboard contents are encrypted in the originating application before transport. TLS protects public relay connections in addition to the client Noise session; the relay has no payload decryption key.

- X25519 and established Noise patterns authenticate/encrypt sessions.
- Ed25519 signs membership, revocations, originating items and pin preferences.
- XChaCha20-Poly1305 protects SQLite payloads and preview records; associated data binds their headers.
- BLAKE3 hashes content; stored content tags are keyed to reduce guessed-content lookup.
- Pairing requires both human approvals, an expiring authorization token and a transcript-bound verification number.
- Revocation is enforced against connections and future content. Retained copies already delivered to a removed device cannot be remotely erased.

Desktop/iOS identities use native credential storage through keyring. Android identities are AES-GCM encrypted with a per-profile Android Keystore key. Existing profiles fail closed if their secure identity disappears; the app does not silently create a replacement or store private keys in plain JSON.

iOS extension handoff uses App Group files protected by complete iOS Data Protection. Android handoff/cache uses Keystore-backed encryption. Keyboard extensions read their cache and insert selected text; they do not scrape host text fields or synchronize clipboard contents themselves.

## Limits

Payload encryption does not hide all metadata. Local headers include device IDs, names, timestamps and item types. A relay/proxy can observe IPs, timing, route lifetime and traffic size. Pair tickets occur in URL queries; deployment logs must redact those queries.

The local source/security review found and fixed public-ID relay route prediction, idle route cache exhaustion, and reconnect payload accumulation. Automated tests cover authentication, signatures/tampering, revocation, malformed data, expiry, replay, catch-up and relay takeover.

This is a focused implementation review, not an independent cryptographic certification. Apple/Windows native device behavior requires target-platform acceptance. [Review record](security-review.md) and [platform limits](platform-limitations.md) distinguish source implementation from runtime evidence.
