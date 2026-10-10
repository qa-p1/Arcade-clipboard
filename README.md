# Arcade Clipboard

Arcade Clipboard keeps an encrypted copy history in sync across your own devices. Copy on one device, then open the picker on another to find and paste that clip.

## Install

Install Clipboard from **Arcade Tools → Apps**, or install it by hand using the [getting-started guide](docs/user/getting-started.md).

## Works with other Arcade apps

Clipboard shares clips with other Arcade apps to inspect, transform, or save them, and syncs them to your paired devices. See [how Clipboard works with other Arcade apps](docs/user/with-other-apps.md).

Read the [Arcade Clipboard user guide](docs/user/) for pairing, platform setup, features, shortcuts, and help.

## Development

The desktop app uses Flutter with a Rust core. The Rust core also runs the relay service; mobile builds provide share targets and clipboard keyboards.

- [Development guide](docs/development.md): build, tests, CI, debugging.
- [Linux guide](docs/linux.md): requirements, desktop integration, and troubleshooting.
- [Architecture](docs/architecture.md): app, Rust core, native code, capture, and sync.
- [Protocol](docs/protocol.md): pairing, wire format, item kinds, and convergence.
- [Security](docs/security.md): threat model, key storage, and limits.
- [Arcade Link](docs/arcade-link.md): desktop actions and peer behavior.
- [Relay deployment](docs/relay-deployment.md): run a relay with Docker, Caddy, or Cloudflare.
- [Platforms](docs/platforms.md): implementation and support details.
- [iPhone setup](docs/ios.md): build and sign the iOS app and extensions.
- [Release packages](docs/releases.md): desktop packages.
- [Status](docs/STATUS.md): implementation and verification record.

The installed desktop command is **arcade-clipboard**. It supports **--version**, **--arcade-manifest**, and **--quit**. On Linux it is installed beside **clipboard**, which is a generic name that can conflict with another command.

The project is licensed under [MIT](LICENSE).
