---
title: Features
order: 3
since: 0.1.0
---

# Features

## Keep a history across devices

Clipboard stores copies from your desktop and syncs them to other paired devices. It supports plain text, links, HTML and RTF, PNG and JPEG images, and files. A text clip is limited to 32 KiB and a clip is limited to 16 MiB. Folders are not supported.

Each device keeps its own encrypted history. Copying a clip again moves its existing entry to the top instead of making a duplicate. You can pin clips and search the history from the picker. A device that has been offline catches up when it reconnects, while the clips are still in history.

## Pause automatic capture

**Private mode** pauses desktop clipboard capture and denies actions that would send clip content to other apps or devices. It does not delete history. Turn it off to resume normal capture.

Clipboard skips sources that mark their clipboard contents as sensitive, such as password managers that use the supported sensitive-content hint.

## Paste from the picker

Open the picker with the global shortcut. Type to search, move through results with the arrow keys, and press Enter. On supported desktops, Clipboard returns focus to the app you were using and pastes the clip. If automatic paste is unavailable, the clip is copied and you can paste it yourself.

A received clip only enters history. Clipboard does not replace the system clipboard until you choose that clip.

## Pair nearby or remote devices

Pair with a QR code and compare the six-digit verification number. Devices discover each other directly on the local network. For devices on different networks, configure an optional relay on every device. The relay forwards traffic between devices that are online at the same time; it does not store clips.

The device that created the mesh can approve new devices and remove members. There is no account or cloud clipboard server.

## Use sharing on phones

On iPhone and iPad, use the share extension or clipboard keyboard to add or choose content. Sync continues only while the iOS app is open. Android includes a share target and clipboard keyboard in its build, but the app has not been run on an Android device.

## Open and use clips with other apps

When enabled, the picker and clip menus offer actions such as **Quick Look** with Look, **Analyze with Lens**, **Extract text**, and **Pin** with Lens, **Format JSON**, **Clean text**, and **Convert to PNG** with Box, and **Add to Shelf**. Results imported from these actions become new history clips and can sync to your devices. They do not change the system clipboard.

If an image is too large for normal sync, Clipboard may offer an opt-in compression through Box. The original oversized image is not inserted into history or sent uncompressed.

See [Works with other Arcade apps](with-other-apps.md) for the full action list.
