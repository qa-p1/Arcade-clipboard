---
title: Works with other Arcade apps
order: 4
since: 0.1.0
---

# Works with other Arcade apps

Enable **Connect with other Arcade apps** in Clipboard’s Connected apps settings. You can turn each installed peer off separately. A peer action appears only when it can handle the selected clip.

| App | What it adds to Clipboard or receives from it |
|---|---|
| Arcade Box | Format JSON, Clean text, and Convert to PNG. Box results can become new clips. Clipboard can also send selected clips to your devices. |
| Arcade Lens | Analyze an image, extract text, or pin an image. Lens results can become new clips; Clipboard can send a clip to your devices. |
| Arcade Look | Quick Look at a supported image or file. Clipboard can send the clip to devices without leaving the picker. |
| Arcade Shelf | Add a clip to Shelf. Text, links, rich text, images, and files can be passed to Shelf. |
| Arcade Find | Find can send selected results to your devices through Clipboard. Clipboard has no Find-specific action in its own clip menu. |
| Arcade Wheel | Clipboard exposes **Send to my devices** for compatible content. It does not register a Wheel-specific action. |
| Arcade Tools | Install, update, or remove Clipboard in Tools’ **Apps** tab. Tools can host the tray icon while Clipboard continues to run in the background. |

Other Arcade apps can send content to your devices with **Send to my devices**, or open Clipboard’s picker and ask you to choose a clip. The picker returns the chosen clip to the requesting app instead of pasting it. Nothing exposes your history unless you choose a clip.

The latest Shelf action is present in the Link offer data, but the current STATUS records only a mock-peer test for the action; it has not yet been confirmed by rebuilding the desktop UI and running it against a real Shelf. See [Arcade Link details](../arcade-link.md).
