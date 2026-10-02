# iPhone and iPad

The iOS app syncs clipboard history with your other devices while it is open. It also adds two system integrations:

- **Share extension.** Choose Arcade Clipboard in any share sheet to add text, links, images or files to the mesh.
- **Clipboard keyboard.** A keyboard that lists recent clips from the mesh. Tap one to insert it into the current text field.

iOS 15 or later is required.

## Build the IPA

The IPA is built by GitHub Actions on a macOS runner, so you do not need a Mac.

1. Open the repository on GitHub and go to **Actions → Build iPhone IPA**.
2. Click **Run workflow**. No certificate or Apple account is needed.
3. When the run finishes, download the **Arcade-Clipboard-iPhone-unsigned** artifact.

The artifact contains:

| File | Purpose |
| --- | --- |
| `Arcade-Clipboard-iOS-unsigned.ipa` | The app with both extensions, built for arm64 devices and unsigned |
| `Arcade-Clipboard-iOS-unsigned.ipa.sha256` | Checksum of the IPA |
| `iPhone-installation.md` | A copy of this document |

Before uploading, the workflow checks that the app and both extensions are arm64, have matching version numbers and the expected extension types, and that the Rust core is linked into the app. The run summary lists the bundle identifiers, versions and the IPA checksum.

## Sign and install

Sign the IPA with the tool you normally use for sideloading, using your own certificate and provisioning profiles. The IPA contains three bundles:

| Bundle | Identifier |
| --- | --- |
| App | `dev.arcade.clipboard` |
| Share extension | `dev.arcade.clipboard.share` |
| Keyboard extension | `dev.arcade.clipboard.keyboard` |

**All three must be signed with the App Group `group.dev.arcade.clipboard`.** The extensions talk to the app only through files in that group. If your signer removes the App Group or gives each bundle a different one, the app still installs and syncs, but shares are never imported and the keyboard stays empty.

If your signing tool changes the bundle identifiers, it must keep the extensions as children of the app's identifier and keep the App Group identical on all three.

## First run

1. Open the app and choose **Join an existing mesh**. iOS asks for **Local Network** access at this point. Allow it: without it the app cannot reach your other devices.
2. Scan the QR code shown on your other device under **Devices → Add device**. Allow camera access when asked. You can also import a screenshot of the code or paste the pairing code.
3. Check that both devices show the same six-digit number and approve on both.
4. Keep the app open while the initial history syncs.

If joining reports that the other device cannot be reached, open **Settings → Privacy & Security → Local Network** and make sure Arcade Clipboard is enabled. Both devices must be on the same Wi-Fi network, unless you use a [relay](relay-deployment.md).

## Using the keyboard

1. Open **Settings → General → Keyboard → Keyboards → Add New Keyboard** and choose **Arcade Clipboard**.
2. In any app, switch to it with the globe key.
3. Tap a clip to insert it. Use **Pinned** to see pinned clips, and the search field to filter. The search field has its own small letter keys so the host app's text is not touched.
4. Press the globe key to return to your usual keyboard.

The keyboard shows text clips only and reads them from a copy the app saves whenever its history changes. Open the app to refresh that copy; if the copy is missing or older than seven days, the keyboard asks you to. The keyboard never reads what you type and has no network access.

**Full Access** is not normally needed. Some iOS versions do not let a keyboard read its app's shared files without it. If the keyboard says shared clips are unavailable, turn on **Allow Full Access** for Arcade Clipboard under **Settings → General → Keyboard → Keyboards**.

Password fields and apps that block third-party keyboards always use the system keyboard.

## Using the share extension

Choose **Arcade Clipboard** in a share sheet. It accepts text, one web link, and up to 32 images or files, 16 MB in total. Photos in HEIC format are converted to JPEG, at most 4096 pixels on the long side.

The extension saves the share on the device and closes. The app adds it to the mesh the next time it is open. Shares waiting longer than seven days are discarded.

## How sync works on iOS

iOS suspends apps shortly after they leave the screen, so Arcade Clipboard syncs only while it is open or recently used:

- Opening the app reconnects to your devices immediately and fetches anything that arrived while it was suspended.
- Clips received while the app was closed are not lost. The other devices keep them and send them when the iPhone reconnects, as long as they are still within the history limit.
- Remote clips are added to history only. Tap a clip and choose **Copy** to put it on the iPhone's clipboard.

Devices are found on the local network with Bonjour (`_arcade-clip._tcp`). Bonjour only suggests addresses; each connection is still authenticated against the mesh membership before any data is exchanged.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Pairing fails with "could not reach the mesh owner" | Local Network access is off, or the devices are on different networks. See [First run](#first-run). |
| Shares never appear in history | The App Group is missing or differs between the app and the share extension. Re-sign with the same App Group on all three bundles. |
| The keyboard says shared clips are unavailable | Same App Group issue, or iOS requires Full Access on this version. Check the App Group first, then try Full Access. |
| The keyboard shows old clips | Open the app once; it refreshes the keyboard's copy. |
| The app closes immediately on launch | The signature is invalid or the provisioning profile does not cover the device. Re-sign; the IPA itself is not device-specific. |

## Building on a Mac

With Xcode, Flutter 3.47.2, Rust 1.98.1 and Ruby:

```bash
rustup target add aarch64-apple-ios
gem install xcodeproj --version 1.28.1 --no-document
bash scripts/dev.sh build-ios
```

The IPA is written to `dist/Arcade-Clipboard-iOS-unsigned.ipa`. The build:

1. Runs `scripts/setup-ios.rb`, which adds the share and keyboard extension targets, the shared Swift sources and the App Group entitlements to the Flutter Xcode project. It is safe to run repeatedly.
2. Builds the Rust core as a static library for `aarch64-apple-ios` (`scripts/build-ios-core.sh`). The library is force-loaded into the app executable, and the Dart side looks its functions up in the running process.
3. Runs `flutter build ios --release --no-codesign` and packages `Runner.app` into an IPA with `scripts/package-ios.py`.

To run on a device from Xcode instead, open `apps/flutter_app/ios/Runner.xcworkspace`, select your team for all three targets and register the App Group for that team.
