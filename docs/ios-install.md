# Build and install on iPhone

The **Build iPhone IPA** GitHub workflow runs on macOS, builds the Rust core for arm64 iPhone, builds Flutter without signing, and packages the real app plus Share/Keyboard extensions into an unsigned IPA. It checks executable architecture, extension metadata/versions, the Rust bridge symbol and archive integrity before uploading.

1. Open this repository on GitHub → Actions → Build iPhone IPA.
2. Choose Run workflow. No Apple certificate or password is needed for this build.
3. When it completes, download the Arcade-Clipboard-iPhone-unsigned artifact.
4. Extract it and sign/install Arcade-Clipboard-iOS-unsigned.ipa with your usual tool.

The workflow runs only when started manually. Its summary lists the three bundle identifiers and the IPA's SHA-256; installation notes accompany the artifact. A workflow start is not a completed iPhone build; read the job's result before installing. The app requires iOS 15 or later.

## Signing the extensions

The app, Share extension and Keyboard extension use these identifiers:

| Target | Bundle ID |
| --- | --- |
| App | dev.arcade.clipboard |
| Share | dev.arcade.clipboard.share |
| Keyboard | dev.arcade.clipboard.keyboard |

All three need the same valid App Group, group.dev.arcade.clipboard. Keep the two embedded extensions when re-signing. If your signer rewrites bundle/App Group identifiers, it must keep the three targets and their group consistent. Stripping the App Group can leave the app installable while its share/keyboard storage fails. The installation notes cannot substitute for your signing tool's provisioning support.

Enable the keyboard through iOS Settings → General → Keyboard → Keyboards → Add New Keyboard, then select Arcade Clipboard. Use the globe key to return to your usual keyboard.

Full Access is normally not needed: the keyboard only reads the clips the app saves for it and has no network code. It is offered as a fallback because some iOS versions don't let a keyboard read its app's shared storage without it; the keyboard tells you if that happens. It never reads what you type.

## First test

Create a mesh on Linux. On iPhone choose Join an existing mesh — iOS asks for Local Network access at this point; allow it — then scan the QR, compare the verification code and approve on both devices. Grant camera access when prompted. Keep the app open for initial synchronization. If joining reports that the other device can't be reached, check Settings → Privacy & Security → Local Network → Arcade Clipboard and that both devices are on the same Wi-Fi.

Add a text clip on Linux, open Arcade on iPhone to refresh, then switch to its keyboard in Notes and tap the clip. Share text/image/file from iPhone to Arcade, then reopen Arcade to import and synchronize the pending share. The extension reports this requirement; continuous iOS background networking is not promised.

## Local macOS build

Install Flutter 3.47.2, Rust 1.98.1, Xcode and xcodeproj 1.28.1. Run:

~~~bash
rustup target add aarch64-apple-ios
gem install xcodeproj --version 1.28.1 --no-document
bash scripts/dev.sh build-ios
~~~

The output is dist/Arcade-Clipboard-iOS-unsigned.ipa. [Flutter's iOS build documentation](https://docs.flutter.dev/deployment/ios) describes the native Xcode requirement; this repository packages the unsigned app directly instead of attempting an App Store export.
