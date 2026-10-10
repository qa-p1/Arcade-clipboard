---
title: Troubleshooting
order: 6
since: 0.1.0
---

# Troubleshooting

## A copied item does not appear

Check that **Automatically add desktop copies** is enabled and that Private mode is off. Some password managers mark clipboard data as sensitive; Clipboard skips those copies. Check the platform notes below if automatic capture is not available in your desktop session.

## Devices do not find each other

Confirm both devices are in the same mesh and online. On the same local network they discover one another directly. Across networks, set the same relay address in **Settings → Remote relay** on each device. The relay cannot deliver a stored clip when the sender is offline; both devices need to be online to exchange relay traffic.

Pairing codes expire after two minutes. Create a fresh invite if a scan or code entry is rejected. Compare the six-digit verification numbers before approving the pairing.

## The picker opens but does not paste

On Linux Hyprland and X11, Clipboard attempts to restore the previous app and send the paste shortcut. If that fails, the clip remains copied and you can press **Ctrl+V** yourself.

Other Wayland compositors do not let an app register a global shortcut or type into another window. Bind **arcade-clipboard --overlay** in the compositor’s keyboard settings; choose a clip and then paste yourself. Clipboard capture also needs a compositor that supports the data-control protocol. GNOME does not allow background clipboard capture.

## The global shortcut is unavailable

Open Settings and choose a different shortcut if another app or the compositor already owns it. On Linux Wayland desktops other than Hyprland, bind **arcade-clipboard --overlay** from the desktop’s keyboard-shortcut settings.

## Clipboard cannot open or unlock its profile on Linux

Make sure a Secret Service provider such as GNOME Keyring or KWallet is running and its keyring is unlocked. Clipboard stores its device identity there and does not silently create a replacement identity when the key is missing.

On Wayland, check that **wl-clipboard** is installed. On X11, automatic paste needs the X11 integration tools listed in the [Linux platform guide](../linux.md).

## I am on Windows or macOS

Both desktop builds and core tests pass in CI, but neither app has been run interactively on a real desktop. Installers are not yet verified. If a desktop-specific problem occurs, report it with the operating-system version and app logs.

## Sync on iPhone or Android

iOS sync runs only while the app is open. The Android build has not yet been tested on a device.
