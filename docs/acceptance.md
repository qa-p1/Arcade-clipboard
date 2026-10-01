# Acceptance

Use synthetic text/images/files and distinct profiles. Record the tested artifact/toolchain and platform rather than relying on status prose.

## Automated

~~~bash
bash scripts/dev.sh check
bash scripts/dev.sh test
dbus-run-session -- bash tests/with-secret-service.sh
bash scripts/dev.sh native-test
~~~

Core tests cover Noise/tampering, pairing consent/replay, offline delivery, revocation, binary limits, signed provenance/pins and forced LAN-to-relay recovery. Flutter tests cover onboarding, errors, history/search/settings and picker controls. Native acceptance uses actual profiles/key storage and a separate GTK editor.

## Two-device manual pass

- Create/join through QR; compare and approve matching verification numbers.
- Add exact text including Unicode/whitespace. Confirm one item on the recipient.
- Confirm its normal OS clipboard did not change.
- Invoke picker, move selection, press Enter; confirm text in the previously focused editor.
- Test Escape and shortcut rebinding/conflicts.
- Add HTML/plain text, image and file group; inspect/copy/export on the other device.
- Disconnect LAN with relay configured; confirm continued delivery, then LAN recovery.
- Close one device, add clips, reopen; receive them once.
- Pin/unpin while disconnected; confirm convergence after reconnect.
- Revoke a device; confirm active connections close and later content is rejected.
- Exercise private mode, retention, count limits, clear history and restart persistence.

## iPhone pass after signing

- Verify the app and both extensions retain one App Group.
- Create/join, grant camera/local-network permission when requested.
- Share text/image/file to Arcade; reopen the app and confirm mesh delivery.
- Enable Arcade keyboard, refresh the main app, switch keyboard in Notes, select a text clip.
- Search using internal keys, use Pinned and switch back with the globe.
- Confirm secure fields/apps that reject third-party keyboards use their system behavior.
- Suspend/reopen; verify pending handoff survives and imports once.

Actions produces an unsigned IPA; downloading it alone does not prove signing or runtime acceptance.
