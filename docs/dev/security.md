# Security

## What is protected

Arcade Clipboard is designed so that only devices you approved can read your clips:

- **In transit.** Clips are encrypted end to end between devices with the Noise protocol. A relay or anyone on the network sees only ciphertext. Relay connections additionally use TLS.
- **At rest.** Each device stores its history encrypted, with a key kept in the platform credential store.
- **Membership.** A device can join only after a person approves it on both devices and compares a verification number. Every connection is checked against the owner's signed membership list.
- **Origin.** Every clip is signed by the device that created it. A member can forward another member's clip but cannot change it or claim to be its author.

## Threat model

| Party | Can | Cannot |
| --- | --- | --- |
| Someone on your network | See that devices connect, when, and how much data moves | Read clips, join the mesh, impersonate a device |
| The relay operator | See device IP addresses, connection timing and traffic volume | Read clips, join the mesh, inject or change clips |
| Someone who sees the QR code | Try to join within its two-minute window | Join without the verification number matching and you approving on both devices |
| A removed device | Keep the clips it received before removal | Connect again, receive new clips, or have its new clips accepted |
| Malware running as your user | Read the clipboard, the unlocked keyring and the app's memory | Nothing in this design stops it; the app relies on the operating system for local isolation |

## Cryptography

| Purpose | Mechanism |
| --- | --- |
| Pairing | `Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s`, with the one-time token from the QR code as the pre-shared key |
| Device connections | `Noise_XX_25519_ChaChaPoly_BLAKE2s`; the remote static key must match its membership certificate |
| Membership, revocations | Ed25519 signatures by the mesh owner |
| Clips and pin changes | Ed25519 signatures by the originating device, over a canonical encoding of every field |
| Local storage | XChaCha20-Poly1305 for payloads and previews, with the record header as associated data |
| Content matching | BLAKE3, keyed per profile so that stored tags do not reveal guessable content |
| Relay routes | Route ID and access ticket derived separately from the two devices' X25519 shared secret |

The implementation uses [snow](https://docs.rs/snow) for Noise, [ed25519-dalek](https://docs.rs/ed25519-dalek) and [x25519-dalek](https://docs.rs/x25519-dalek) for keys, and RustCrypto's `chacha20poly1305`.

## Pairing

1. The owner creates an invite containing a random token valid for 120 seconds, shown as a QR code.
2. The joining device connects and runs a Noise handshake keyed with that token.
3. Both devices derive a six-digit number from the handshake transcript and display it. If a third party were in the middle, the numbers would differ.
4. A person approves on both devices. Only then does the owner sign a membership certificate for the new device.

Tokens are single use. An expired or used token is rejected.

## Key storage

| Platform | Where device keys are stored |
| --- | --- |
| Linux | Secret Service, such as GNOME Keyring or KWallet |
| macOS, iOS | Keychain |
| Windows | Credential Manager |
| Android | A file encrypted with an AES-GCM key held in Android Keystore |

If the stored identity for an existing profile is missing or damaged, the profile does not open. The app never creates a replacement identity silently and never writes private keys in plain text.

On iOS the Keychain entry's name is derived from the profile's path relative to the app container, because the container's absolute path changes when the app is updated.

## Mobile extensions

- The iOS share extension and keyboard communicate with the app through files in the App Group container, written with complete data protection. They are readable only by the three signed bundles and only while the device is unlocked.
- On Android, the share target and keyboard exchange data with the app through files encrypted with a Keystore key.
- Neither keyboard reads the text around the cursor or what you type. They insert only the clip you tap.
- Extensions validate sizes, MIME types and file names before saving, and the app validates them again before capture.

## Desktop clipboard

- Content marked sensitive by password managers (`x-kde-passwordManagerHint`, `application/x-keepassxc-clipboard`) is never captured.
- Clips received from other devices are never written to your clipboard automatically. Your clipboard changes only when you choose a clip.
- Before pasting, the app confirms that the remembered window still exists and belongs to the same process instance.
- **Private mode** stops capture entirely.
- Diagnostic logs (`ARCADE_DEBUG=1`) record events only, never clipboard contents.

## What is not protected

- **Metadata.** Device IDs, device names, timestamps and clip types are stored unencrypted in local record headers so that history can be listed and synced. Network observers and the relay see IP addresses, timing and traffic volume.
- **Delivered clips.** Removing a device stops future sync but cannot erase what it already received.
- **Relay tickets in URLs.** Relay access tickets are passed in query strings. The supplied Caddy configuration does not log requests; any proxy or monitoring you add must not log query strings either.
- **Local compromise.** Anything running as your user can read the clipboard and the unlocked keyring.

## Review checklist

Check these before a release:

- [ ] Invite tokens expire after 120 seconds, are single use, and pairing requires matching verification and both approvals.
- [ ] Every connection's Noise static key matches an owner-signed, unrevoked certificate.
- [ ] Clip and pin signatures cover every canonical field; tampered items are rejected.
- [ ] Revoked devices cannot connect or author accepted clips.
- [ ] A missing or damaged identity fails closed.
- [ ] Database records fail to decrypt if their header is altered; schema migrations roll back on error.
- [ ] Frame, chunk, MIME type, image dimension, file name and queue limits are enforced.
- [ ] Deletion tombstones survive restarts and prevent deleted clips from returning.
- [ ] Relay routes cannot be guessed from public device IDs; idle reservations cannot exhaust the route table.
- [ ] Logs contain no clipboard contents or relay tickets.
- [ ] Sensitive clipboard content is skipped; paste targets are verified.
- [ ] Mobile shared storage stays within the App Group (or Keystore encryption) and respects its size and age limits.

Most of these are covered by the Rust tests (`cargo test --workspace`).
