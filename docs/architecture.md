# Architecture

Arcade Clipboard keeps shared clipboard history separate from the operating system clipboard. A remote item is stored in the mesh history; only a user choosing it may copy or paste it into the local application.

## Module boundaries

| Module | Responsibility in this checkout |
| --- | --- |
| `apps/flutter_app` | Shared onboarding, history, device management, settings, pairing UI, and desktop picker source |
| `core/rust` | Device and mesh identity, membership, pairing, direct transport, encrypted local history, deduplication, and sync state |
| `platform/desktop/arcade_desktop_bridge` | Small native clipboard, shortcut, window-target, and paste capability adapters |
| `platform/android` | Android share/IME and encrypted local handoff source |
| `platform/ios` | iOS share extension, clipboard keyboard, and App Group handoff source |
| `services/relay` | Standalone, bounded opaque WebSocket transport; not connected as a client fallback |
| `tests/driver` and `tests` | JSON-lines Rust driver and automated/manual test source |

Flutter owns consumer presentation and interaction. Rust owns the shared protocol, trust checks, storage, and synchronization. Native code is limited to operating-system integration. Flutter/Rust binding generation and platform runners are build prerequisites and are absent from the checked-in app directory.

## Current topology and trust

The mesh creator is its authority. Devices generate their own identities; a join invitation carries short-lived bootstrap authorization and public information, not the creator's private keys. The source implements a Noise-based authenticated pairing flow with matching human confirmation and signed membership. After pairing, members connect directly to the authority over TCP; the authority forwards accepted clips to other active members. Discovery, automatic remote relay fallback, and a fully connected peer topology are not implemented.

The relay is a separate transport service and is outside the clipboard trust boundary. It forwards opaque frames for paired routes, but the current Flutter/Rust client does not connect to it. Consequently this checkout does not provide reliable synchronization across CGNAT or when a direct owner connection cannot be made.

## Data flow

1. Desktop capture or an explicit mobile share submits text to the Rust boundary.
2. Rust validates the item, assigns stable identity and provenance, and stores its payload encrypted locally.
3. Authorized devices exchange protocol messages over an authenticated encrypted direct session.
4. The receiver validates membership and deduplicates before adding the item to its history.
5. Flutter refreshes history; native integrations expose an explicit copy/paste or keyboard-insertion action.

The implemented wire format is versioned and text/URL-focused. Images, arbitrary files, rich clipboard representations, and negotiated content capabilities are future work. See [protocol](protocol.md).

## Readiness

This document describes source boundaries, not verified product behavior. The Flutter bridge and runners have not been generated in this checkout; desktop and mobile integrations have not passed real-device acceptance. See [development](development.md), [platform limitations](platform-limitations.md), [security review](security-review.md), and the [acceptance checklist](acceptance.md). The current security review is not a release sign-off.
