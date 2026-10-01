# Security regression checklist

Review these boundaries on the exact artifact:

- Pair token expiry/consumption, matching human verification and both approvals.
- Noise identity matched to owner-signed membership.
- Origin/pin signatures bind all canonical fields and reject tampering.
- Revoked members cannot establish new sync sessions or author accepted future items.
- Missing secure keys fail closed; no plaintext identity/config fallback.
- SQLite payload/preview authentication and migration rollback.
- Chunk/frame, MIME, image dimension, file name and queue bounds.
- Deduplication/tombstones survive restart and suppress loops.
- Relay routes require pairwise secret knowledge; inactive reservations cannot exhaust capacity indefinitely.
- Relay/proxy logs exclude bearer query tokens and clipboard plaintext.
- Native clipboard sensitivity flags, safe file grants and remembered target identity.
- Share/keyboard App Group isolation, protected storage, expiry and cache bounds.

See security-review.md for resolved findings and platform-limitations.md for target-device checks that remain.
