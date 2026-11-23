---
title: Works with other Arcade apps
order: 4
since: 0.1.0
---

# Works with other Arcade apps

Enable **Connect with other Arcade apps** in Clipboard’s Connected apps settings. You can turn each installed peer off separately. A peer action appears only when it can handle the selected clip. Each app says what it can do, so the menu shows an app's newer actions without a Clipboard update; it lists at most four from one app, the ones that app ranks first for that kind of clip.

| App | What it adds to Clipboard or receives from it |
|---|---|
| Arcade Box | Its tools for the clip: for an image, converting and compressing; for text, cleaning and formatting. Box results can become new clips. A copied photo too large to sync can be compressed through Box. |
| Arcade Lens | Read text, scan codes, analyze or pin an image, and find links and other details in text. Lens results that are text can become new clips. |
| Arcade Look | Quick Look at a supported image or file. Clipboard can send the clip to devices without leaving the picker. |
| Arcade Shelf | Add a clip to Shelf. Text, links, rich text, images, and files can be passed to Shelf. |
| Arcade Find | Find can send selected results to your devices through Clipboard. Clipboard has no Find-specific action in its own clip menu. |
| Arcade Wheel | Clipboard exposes **Send to my devices** for compatible content. It does not register a Wheel-specific action. |
| Arcade Tools | Install, update, or remove Clipboard in Tools’ **Apps** tab. Tools can host the tray icon while Clipboard continues to run in the background. |

Other Arcade apps, your file manager's Arcade menu and the browser extension can send content to your devices with **Send to my devices**: text of any length up to 16 MB, links, images and files (up to 32 at a time, 16 MB in all). A clip goes to all your devices; there is no way yet to pick one device. They can also open Clipboard’s picker and ask you to choose a clip. The picker returns the chosen clip to the requesting app instead of pasting it. Nothing exposes your history unless you choose a clip.

The latest Shelf action is present in the Link offer data, but the current STATUS records only a mock-peer test for the action; it has not yet been confirmed by rebuilding the desktop UI and running it against a real Shelf. See [Arcade Link details](https://github.com/qa-p1/Arcade-clipboard/blob/main/docs/dev/link.md).
