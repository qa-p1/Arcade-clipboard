---
title: Getting started
order: 2
since: 0.1.0
---

# Getting started

## Install Arcade Clipboard

Install from **Arcade Tools → Apps** to install, update, or remove Clipboard. Tools can host its tray icon in one Arcade icon while running; Clipboard keeps its own icon when Tools is closed.

### Linux

Download and run the AppImage. On first launch, choose **Install** to add Clipboard to your app launcher, put it in **~/Applications/Arcade/**, add **arcade-clipboard** in **~/.local/bin**, and choose whether it starts at login. Choose **Just run it once** to use it without installing. If **~/.local/bin** is not on PATH, the installer shows the exact line for your shell.

You can also use the Linux tarball and **install-linux.sh** for one release. An unlocked Secret Service keyring such as GNOME Keyring or KWallet is needed for the device identity. Wayland capture needs **wl-clipboard**. On other Wayland desktops, you may need to bind **arcade-clipboard --overlay** yourself.

To uninstall, run **arcade-clipboard --uninstall**, use the launcher’s **Uninstall** action, or remove it from Arcade Tools. Settings stay unless you choose to remove them.

### Windows

Run the installer. It installs for your user without administrator access, adds a Start menu entry, offers a desktop shortcut and start-at-login options, and adds **arcade-clipboard** to PATH. If SmartScreen warns about the unsigned installer, choose **More info → Run anyway**. Uninstall from **Settings → Apps** or Arcade Tools.

### macOS

Open the dmg and drag Clipboard to Applications. If you run it from the dmg or Downloads, Clipboard offers to move itself to Applications. The app is not notarized, so right-click it and choose **Open** the first time.

### iPhone and iPad

The iOS app is distributed as an unsigned IPA that you must sign and install with your own signing tool. Follow the [iPhone setup guide](../ios.md).

Android builds exist, but have not been tested on a device; there is no verified install workflow to recommend yet.

## Pair your devices

1. On the first device, choose **Create a mesh** and give it a name.
2. Choose **Devices → Add device**. Clipboard shows a QR code and pairing code that expire after two minutes.
3. On the second device, choose **Join an existing mesh**, then scan the QR code or enter the code.
4. Compare the six-digit verification number shown on both devices and approve the pairing on each.
5. Copy a short text snippet on one device. Open Clipboard on the other and check that the clip appears.

The device that created the mesh approves new devices and can remove them. Devices on the same local network find each other directly. To connect from different networks, configure the same relay address in **Settings → Remote relay** on each device.

## Open the picker

The default shortcut is **Ctrl+Shift+Space** on Linux, **Ctrl+Alt+V** on Windows, and **Cmd+Shift+V** on macOS. Change it in Settings if another app already uses it. Select a clip with the arrow keys, type to search, then press **Enter** to paste it into the app you were using.

On Linux Hyprland and X11, Clipboard restores the previous app and pastes for you. On Wayland compositors without support for background input, choosing a clip copies it; paste it yourself with **Ctrl+V**.

## Keep running

Clipboard normally stays in the background so it can capture copies and receive clips. Its tray icon opens Settings; choose **Quit Arcade Clipboard** from the tray menu to stop it.
