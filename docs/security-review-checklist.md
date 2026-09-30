# Release security gate

This checklist is a review gate, not a claim that a release passed it. Record evidence, exact commit IDs, commands, and platform/device details in [verification/checkpoint.md](verification/checkpoint.md).

## Trust boundary

- A new device cannot supply its own trust root to replace an established mesh.
- QR tickets contain no long-term private keys, expire, and authorize one attempt only.
- QR responder key is checked against the authenticated handshake key.
- Both users' matching-code confirmations are required before saving trusted membership.
- Reject malformed, oversized, expired, reused and wrong-version invitations.
- Bind membership certificate to device ID, public key, mesh ID and authority.
- A copied invitation alone cannot silently finish pairing without owner confirmation.

## Transport and history

- Every clip crosses a network only within an authenticated encrypted channel.
- Relay never receives decryption keys or plaintext previews.
- Authenticate peer before accepting history or presence updates.
- Check item size, timestamp policy, source authorization, version and expiry before storage.
- Clip IDs survive forwarding and reconnect. Persistent deduplication covers app restart.
- Deletes cannot be undone by old peers replaying retained history.
- Unknown content types fail safely without crashing newer/older peers.
- Link reconnection cannot downgrade peer verification.
- Encryption keys are in platform secure stores; unavailable store fails clearly.
- Local payload ciphertext is authenticated. No plaintext payload index/log/exception leak.
- Cache/share-extension data is protected by OS storage controls and documented.

## Revocation

- Only the mesh authority issues membership/removal changes in v1.
- Removal stops active and future transmissions to that identity.
- Existing peers verify removal authority and reject rollback/replay of old trust state.
- Offline peers and previously delivered content have explicit limitations.
- No claim that revocation deletes content already delivered to another device.

## Platform boundary

- Capture respects pause state and sensitivity metadata that the platform exposes.
- Selecting a mesh item cannot re-originate it through clipboard watcher callbacks.
- Native text input is passed as data, never interpolated into shell programs.
- Failed focus restoration must not paste into an unrelated application.
- Clipboard restoration never overwrites a newer copy made by the user.
- Wayland support is based on available compositor/portal capability.
- Extensions do not record typed text or bypass secure-field restrictions.
- Native input/cache files have bounded counts and sizes; atomic writes protect corruption.

## Release evidence

- Tests cover modified ciphertext, wrong peer, replay, expired invite and revoked identity.
- Run end-to-end tests using real sockets and separate core instances.
- Test actual focus/paste on each advertised OS. A compile is insufficient.
- Review worker code separately before release; unresolved critical findings block shipping.
