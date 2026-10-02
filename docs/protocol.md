# Protocol

This describes version 1 of the device-to-device protocol implemented in `core/rust`. [Security](security.md) explains the reasoning behind these choices.

## Framing

Every message is a JSON object, sent as a frame with a 4-byte big-endian length prefix. After the handshake, each frame is a Noise ciphertext of at most 65,535 bytes including the authentication tag. The same framing is used over TCP and, through the relay, over binary WebSocket messages.

Unknown JSON fields are ignored, so fields can be added without a version change. Unknown message types and unsupported protocol versions close the connection.

## Pairing

Pairing uses `Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s`. The QR code carries the mesh ID, the owner's address, port, device ID and public keys, an optional relay URL, and a random token used as the pre-shared key. The token expires after 120 seconds and is consumed on use.

After the handshake, both devices display a six-digit number derived from the handshake transcript. The user compares the numbers and approves on both devices. The owner then signs a membership certificate for the new device and sends it the current membership list. The new device is stored only after both approvals; a rejected or interrupted pairing leaves no partial state.

## Membership

A certificate binds:

- mesh ID and device ID,
- the device's Noise static public key (X25519),
- its item-signing public key (Ed25519),
- its name, platform and capabilities.

The owner signs certificates and revocations with Ed25519. Devices exchange membership records at the start of every connection, so a revocation spreads even when the owner is offline.

## Device sessions

Paired devices use `Noise_XX_25519_ChaChaPoly_BLAKE2s`. Each side checks that the other's static key matches an unrevoked certificate for the mesh. The first message after the handshake is a hello that carries the sender's listening port, so the receiver can record an address to call back.

When two devices dial each other at the same moment, both may end up with two sessions. Each side keeps the session whose handshake hash is smaller, which both sides compute identically. Heartbeats run every 15 seconds; a session whose heartbeat cannot be sent is closed.

## Items

An item (a clip) contains:

| Field | Description |
| --- | --- |
| `protocol_version` | Protocol version |
| `id` | UUID, stable across forwarding, resend and catch-up |
| `origin_device`, `sender_sequence` | Device that created the item and its per-device sequence number |
| `source_name` | Name of the originating device, shown in history |
| `created_at`, `expires_at` | Creation and expiry times in milliseconds |
| `kind` | `text`, `url`, `rich_text`, `image`, `file` or `files` |
| `text` | Plain text, at most 32 KiB |
| `representations` | MIME type, base64 data and optional file name for each format |
| `content_hash` | BLAKE3 hash of the content |
| `origin_signature` | Ed25519 signature by the origin over the canonical item |

The total decoded size is limited to 16 MiB across at most 32 representations. HTML or RTF can be sent together with plain text. PNG and JPEG images have their dimensions checked. File names must be plain names, with no path separators. Files are sent as content, never as paths on the sender's disk.

An item that arrives again with the same ID but different content is rejected.

## Transfer

Items larger than one frame are split into 24 KiB chunks. The sender waits for queue space before producing more, so memory use stays bounded. If a connection drops during a transfer, the item is sent again from the start on the next connection.

## Catch-up

At the start of every session, the two devices exchange, in order:

1. membership records and revocations,
2. pin states,
3. the IDs of retained items,
4. the items the other side does not have, one payload at a time.

Each device remembers the item IDs it has already seen and deleted, so an item is never applied twice and a deleted item is not restored by a device that missed the deletion.

## Pins and deletion

A pin change is a signed record with a Lamport counter. The record with the higher counter wins, and ties are broken by device ID, so all devices reach the same state regardless of the order in which they receive changes.

Deleting an item leaves a tombstone, kept for 31 days. Copying content that already exists in history deletes the older item on every device and creates a new one, which moves the content to the top.

## Retention

Each device applies its own **Keep history** period (default 24 hours) and **History limit** (default 500 items, at most 10,000). Pinned items do not expire but count toward the item limit.

## Relay

Devices that cannot reach each other directly can meet at a relay. The relay forwards binary WebSocket messages between two sockets without reading them; the Noise session inside is the same as over TCP.

- **Pairing route:** `/v1/relay/{session_id}?token={ticket}`, where the session ID and ticket come from the invite.
- **Paired route:** `/v1/relay/paired/{route_id}/{slot}?token={route_token}`. The route ID and token are derived separately from the two devices' X25519 shared secret, so knowing a device's public ID does not reveal its route. Slots `a` and `b` are assigned by device ID order.

The relay keeps no queue. Both devices must be connected at the same time; anything missed is delivered by catch-up on the next session. The server side is documented in [services/relay](../services/relay/README.md).
