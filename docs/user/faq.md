---
title: FAQ
order: 5
since: 0.1.0
---

# Frequently asked questions

## Does Arcade Clipboard use an account or store clips on a server?

No. Devices pair directly, and traffic is end-to-end encrypted. An optional relay forwards traffic between devices that are online at the same time and does not store it.

## Why does copying something on another device not replace my clipboard?

Receiving a clip only adds it to Clipboard’s history. Select the clip in the picker when you want it copied or pasted.

## Can I share folders?

No. Clipboard shares files, but not folders. A transfer that is interrupted restarts from the beginning.

## Does the relay keep clips while devices are offline?

No. A relay only forwards traffic between devices online at the same time. Offline devices catch up from other devices when they reconnect, while those clips remain in history.

## Does Private mode delete my clips?

No. Private mode pauses desktop capture and blocks sending clip content. It leaves existing history intact.

## Which platforms have been run on a real desktop?

Linux, with Hyprland, was tested end to end on real hardware. Windows and macOS builds and Rust core tests pass in CI, but neither desktop app has been run interactively on those systems. The installers are not yet verified.

The Android build has not been tested on a device. On iPhone and iPad, iOS limits sync to periods when the app is open.
