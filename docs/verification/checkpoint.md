# Verification checkpoint — 2026-09-30

This document records the evidence level of the source checkpoint, not a release approval.

## Current evidence

| Area | Evidence in this checkout | Status |
| --- | --- | --- |
| Rust core, protocol, encrypted local storage | Source and unit/integration test files are present | Not executed for this checkpoint |
| Relay | Standalone source and WebSocket test files are present | Not executed for this checkpoint; no client fallback is wired |
| Flutter UI and Rust bridge | Dart source and state-test files are present; generated bindings are absent | Not built or analyzed; Flutter toolchain block is recorded in [toolchain-blocker.md](toolchain-blocker.md) |
| Desktop adapters | Native source exists for Windows, macOS, X11, and Hyprland paths | No native build or live desktop acceptance performed |
| iOS / Android | Share, keyboard, and handoff source exists | No native build, emulator, or physical-device acceptance performed |

No automated, native, or emulator tests were run while preparing this publishing checkpoint, per the user's instruction. Test source files and a CI workflow are not execution evidence.

## Readiness gates

Before asking the user to test this on Hyprland, generate and build the Linux Flutter runner and bridge on a trusted Flutter installation, fix and verify the `wl-paste` MIME detection path, then complete the Linux steps in [acceptance.md](../acceptance.md). The current checkout is not yet a working Hyprland test build.

Before asking the user to test on iPhone/iPad, generate the iOS runner and bridge, correct and validate the Xcode project installer, build and sign all targets with the registered App Group, and complete physical-device share, keyboard, pairing, and sync checks. The current checkout is not yet a working iOS test build. Android mesh startup remains blocked by missing Rust secure identity storage.

Any release-readiness record must name the exact candidate commit and list successful build, test, and device checks separately. A source review or passing core tests alone does not establish desktop/mobile acceptance or security sign-off.
