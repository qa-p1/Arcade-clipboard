# Arcade Clipboard

Arcade Clipboard keeps one clipboard history across your own devices. Copy something on your PC and it shows up in the history on your phone and your other computers. Open the picker with a shortcut, choose a clip, and it is pasted into the app you were using.

Devices pair directly with a QR code. There is no account and no server that can read your clips: everything is end-to-end encrypted, and history is stored encrypted on each device.

## How it behaves

- **Copying adds to the mesh.** On the desktop, every normal copy (Ctrl+C, a menu's Copy, a screenshot tool) is added to history and sent to your other devices. Turn on **Private mode** to pause this.
- **Receiving never overwrites your clipboard.** A clip from another device only appears in history. Your clipboard changes only when you choose a clip.
- **Copying something again moves it to the top.** If you copy text that is already in history, the existing entry moves to the top on every device instead of creating a duplicate.
- **The picker pastes for you.** Press the shortcut (Ctrl+Shift+Space on Linux), move with the arrow keys or type to search, then press Enter. The picker closes, focus returns to your app, and the clip is pasted. Terminals get Ctrl+Shift+V.
- **Devices keep syncing when the creator is away.** The device that created the mesh approves new devices and can remove them. Once paired, any two members sync directly.

Supported content: plain text (up to 32 KiB), links, HTML and RTF, PNG and JPEG images, and files. A single clip can be up to 16 MiB.

## Works with other Arcade apps

Desktop clip menus and the picker can **Quick Look** with Look, **Extract text**,
**Analyze with Lens** or **Pin** an image, and **Format JSON**, **Clean text** or
**Convert to PNG** with Box. Results join your clipboard history and devices;
your system clipboard stays unchanged. An oversized copied photo can wait for
an opt-in **Compress** before it syncs. Entries appear when the peer is installed,
enabled and available; standalone behavior stays the same.

Choose peers in **Settings → Connected apps**. Other apps can send content to your
devices or open your picker through the [documented Link actions](docs/arcade-link.md).
Phones receive those clips through the mesh and do not participate in local Link.

## Platform support

| Platform | Status |
| --- | --- |
| Linux, Hyprland | Full support: automatic capture, global shortcut, picker, automatic paste. The primary platform, tested end to end. |
| Linux, X11 | Automatic capture, global shortcut, picker, automatic paste through `xdotool`. |
| Linux, other Wayland | Automatic capture on compositors with data-control (KDE, Sway, niri, …). Bind `clipboard --overlay` to a shortcut; the chosen clip is copied and you press Ctrl+V. GNOME does not allow background capture. |
| iPhone and iPad | Share extension, clipboard keyboard, sync while the app is open. Built as an unsigned IPA by GitHub Actions; see [iPhone](docs/ios.md). |
| Android | Share target and clipboard keyboard. Builds, but is not yet tested on a device. |
| Windows, macOS | Native integration is written; CI builds the desktop app and runs the Rust core tests on both. It has not been run interactively on those systems. |

Details and known limits are in [Platforms](docs/platforms.md).

## Install

### Linux

Build and install the release bundle (requirements are listed in [Linux](docs/linux.md#requirements)):

```bash
bash scripts/dev.sh build-linux
bash scripts/install-linux.sh
```

The app is installed in `~/.local/share/arcade-clipboard` with a desktop entry. You need an unlocked Secret Service keyring (GNOME Keyring or KWallet), and `wl-clipboard` on Wayland. The CI workflow also publishes the bundle as `Arcade-Clipboard-linux-x64.tar.gz`.

### iPhone

Run **Actions → Build iPhone IPA → Run workflow** on GitHub, download the artifact, then sign and install the IPA with your own signing tool. The app and both extensions must keep the App Group `group.dev.arcade.clipboard`. Step-by-step instructions are in [iPhone](docs/ios.md).

## Pair your devices

1. On the first device, choose **Create a mesh** and give it a name.
2. Open **Devices → Add device**. A QR code appears, valid for two minutes.
3. On the second device, choose **Join an existing mesh** and scan the code. You can also import a screenshot of it or paste the pairing code.
4. Both devices show a six-digit number. Check that they match and approve on both.
5. Copy something on one device. It appears in the other device's history within a moment.

Devices on the same network find each other automatically. To sync across networks, run the [relay](docs/relay-deployment.md) and set its address in **Settings → Remote relay** on every device.

## Documentation

| Document | Contents |
| --- | --- |
| [Linux](docs/linux.md) | Requirements, shortcut and picker, Hyprland details, command-line options, troubleshooting |
| [iPhone](docs/ios.md) | Building the IPA, signing, the share extension and keyboard, troubleshooting |
| [Platforms](docs/platforms.md) | What each platform supports and what it cannot do |
| [Architecture](docs/architecture.md) | How the app, Rust core and native code fit together; capture and sync in detail |
| [Protocol](docs/protocol.md) | Pairing, wire format, items, convergence |
| [Security](docs/security.md) | Threat model, cryptography, key storage, what is not protected |
| [Relay deployment](docs/relay-deployment.md) | Hosting the relay with Docker, Caddy and Cloudflare |
| [Development](docs/development.md) | Building from source, tests, CI, debugging |

## Limitations

- Each device keeps its own history. A device that is offline catches up when it reconnects, as long as the clips are still within the history limit.
- The relay only forwards traffic between devices that are online at the same time. It does not store anything.
- Folders cannot be shared, and an interrupted large transfer restarts from the beginning.
- On iPhone, sync runs only while the app is open; iOS does not allow it to run continuously in the background.

Desktop release packages and installation steps: [Releases](docs/releases.md).

## License

[MIT](LICENSE)
