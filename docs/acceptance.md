# Version 1 acceptance tests

Run these on each advertised desktop OS with a regular editor, not an in-app test field. Use separate application-data directories when testing two clients on one machine. Never use real passwords as test clips.

## First pairing

1. Start two clean clients. Create a mesh on A. Name it so the devices are distinguishable.
2. Open Add device on A and join on B using that invitation.
3. Compare the verification code on both devices. Reject once; neither device should become trusted.
4. Create a fresh invitation, join again, approve both sides. Each should show the other.
5. Try the consumed invitation in clean client C: it must fail. Repeat with an expired invitation.

## Desktop clipboard

1. Put `local clipboard must remain` into B's regular clipboard.
2. Copy a distinctive multi-line Unicode sample on A: `Arcade ✓ हिन्दी\nsecond line`.
3. Confirm B's mesh history receives it once and B's regular clipboard still contains its original value.
4. Focus B's external editor, leaving the caret in the middle of a line.
5. Press the configured mesh shortcut, navigate with arrows, press Enter.
6. The picker closes, the original editor has focus, and the exact text appears at its caret.
7. No new clip appears on A or B because of that paste. Repeat selecting the same mesh clip.
8. Open picker and dismiss with Esc; editor content and clipboard must remain unchanged.
9. Switch focus while paste is being prepared; the app must never paste into an unrelated application.
10. Rebind the shortcut, test the new binding, and verify the old binding is released.

## Connectivity and storage

1. Restart both clients. Trust survives without re-pairing.
2. Disconnect B, add clips on A, reconnect B. Retained clips arrive exactly once.
3. Repeat after application restart and after sleep/wake.
4. With a configured secure relay, block direct LAN communication. Repeat copy/paste.
5. Stop the relay while a direct path exists; LAN continues. Restore it and remove LAN.
6. Pause mesh capture on A. Local copy continues, but no new local items enter mesh history.
7. Test retention boundary, item count limit, oversized text and non-ASCII byte limits.
8. Search text/source/type, delete an item, reconnect an old peer: removed content must not resurrect.

## Revocation

1. Pair A (authority), B and C. Remove C from A.
2. Keep C's process alive and create fresh content on A/B. C must not receive/decrypt it after revocation is applied.
3. Restart C with its old trust data. It must not rejoin via previous credentials.
4. Test B offline during removal. Document the precise authority freshness rule before claiming removal works across the mesh.

## Mobile

1. Share text from Safari/Android browser into the app. Observe queued versus synchronized status accurately.
2. Receive on desktop and paste through its picker into an external editor.
3. Copy on desktop, refresh the mobile client, activate its keyboard in an unrelated app, tap the received text.
4. Confirm exact insertion and next-keyboard behavior; confirm no typed field contents are recorded.
5. On iOS test Full Access denied, secure field, phone field and an app that blocks custom keyboards.
6. Terminate/suspend the main app and repeat sharing/receiving. Record actual lifecycle behavior, not expected background behavior.

## Accessibility and privacy

Verify tab/arrow navigation, focused row visibility, screen reader labels, increased text scale, light/dark, reduced motion and non-color status indications. Inspect diagnostic logs and crash paths using distinctive fake secret text; logs must never contain it. Check payload database and native cache protection separately.
