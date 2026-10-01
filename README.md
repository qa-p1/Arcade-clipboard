# Arcade Clipboard

Clipboard history shared between your trusted devices. Remote clips enter the mesh history; they never replace your normal clipboard automatically. Choose a clip to copy it or paste it into the app you were using.

The shared Flutter client uses a Rust core for identities, encrypted storage, pairing, discovery, LAN/relay connections and synchronization. No account is required.

## Start on Linux

From the repository root:

~~~bash
bash scripts/dev.sh desktop
~~~

For a release bundle:

~~~bash
bash scripts/dev.sh build-linux
./apps/flutter_app/build/linux/x64/release/bundle/clipboard
~~~

The archive is dist/Arcade-Clipboard-linux-x64.tar.gz. Keep the executable beside its lib/ and data/ directories. To install the release in your user application directory, run bash scripts/install-linux.sh. No shell startup files are changed.

An unlocked Secret Service keyring is required. Normal copies (Ctrl+C) are added to the mesh automatically; turn on Private mode to pause. Hyprland supports the full shortcut → picker → Enter → paste flow (Ctrl+Shift+V is sent to terminals). On other Wayland desktops, bind a system shortcut to `clipboard --overlay`; choosing a clip copies it for a manual Ctrl+V. On Wayland, install wl-clipboard (2.2+) for capture.

The app runs as a single instance: launching it again shows the running window, and `clipboard --overlay` opens the picker. Start with `ARCADE_DEBUG=1` to print capture/paste/connection diagnostics (never clipboard contents) to stderr.

## Pair and test

1. Create a mesh on the first device and give it a name.
2. Open Devices → Add device.
3. On the other device, choose Join mesh and scan the QR code, import its image, or paste the pairing code.
4. Compare the verification number and approve on both devices.
5. Add a clip. It should appear in the other device's history without replacing its active clipboard.
6. Open the desktop picker with the shortcut shown in Settings; select a clip and press Enter.

Invites expire after two minutes. The creator approves new devices and removes members; paired members can synchronize while the creator is offline.

## iPhone IPA

GitHub Actions → Build iPhone IPA → Run workflow builds an unsigned arm64 IPA with both native extensions. Download the artifact, extract the IPA, then sign and install it with your usual signing tool. No signing certificate is uploaded to GitHub. See [iPhone build and installation](docs/ios-install.md), especially the App Group requirement.

The iPhone client synchronizes while the main app is running. Shares are saved securely by the extension and imported when the app resumes. The keyboard inserts previously synchronized text from its local cache.

## What is implemented

- Human-confirmed QR pairing, owner-signed membership and actual revocation.
- Noise end-to-end encryption, authenticated origin signatures and encrypted SQLite payloads/previews.
- Trusted peer discovery, LAN preference, encrypted relay fallback and reconnect/catch-up.
- Text, URLs, HTML/RTF, PNG/JPEG, files and file groups; up to 16 MiB per clip.
- Search, source/type filters, inspect, copy, export, resend, synchronized pins and deletion.
- Private mode, automatic capture (on by default), retention and item-count limits.
- Copying something already in history moves it to the top on every device instead of duplicating it.
- Light/dark UI, keyboard navigation, desktop picker and native clipboard formats.
- Linux tray/background behavior, desktop startup controls, native mobile share and keyboard integrations.

Folder transfer and byte-offset resume are not implemented. Interrupted transfers restart from their retained item. There is no public relay configured.

## Development and deployment

~~~bash
bash scripts/dev.sh test
bash scripts/dev.sh check
bash scripts/dev.sh relay
bash scripts/dev.sh native-test
~~~

[Development](docs/development.md) · [Architecture](docs/architecture.md) · [Protocol](docs/protocol.md) · [Security](docs/security.md) · [Platform limits](docs/platform-limitations.md) · [Relay deployment with Cloudflare](docs/relay-deployment.md) · [Acceptance](docs/acceptance.md)

Linux release builds and automated core/client checks have been run locally. Apple/Windows native runtime behavior needs its target platform; an unsigned IPA workflow is a build path, not a claim that this Linux machine tested an iPhone.
