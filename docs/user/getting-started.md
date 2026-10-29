---
title: Getting started
order: 2
since: 0.1.0
---

# Getting started

## Install Arcade Clipboard

Install from **Arcade Tools → Apps** to install, update, or remove Clipboard. Tools can host its tray icon in one Arcade icon while running; Clipboard keeps its own icon when Tools is closed.

### Linux

Download the AppImage, make it executable, and open it. Choose **Install** to copy it into `~/Applications/Arcade`, add the launcher and CLI command, and choose whether to start at login. **Just run it once** leaves the download in place. For an unattended install use `--install --silent --no-launch`; `--repair` restores integration and `--uninstall` removes the app while keeping your data. Add `--remove-data` only when you want to delete the app data too.

The Linux tarball and **install-linux.sh** remain available for one release. Extract the tarball and run `bash install-linux.sh` to copy Clipboard into your user data directory and add it to the app launcher. An unlocked Secret Service keyring such as GNOME Keyring or KWallet is needed for the device identity. Wayland capture needs **wl-clipboard**. On other Wayland desktops, you may need to bind **arcade-clipboard --overlay** yourself.

### Windows

Run the installer. It installs for your user without administrator access, adds a Start menu entry, offers a desktop shortcut and start-at-login options, and adds **arcade-clipboard** to PATH. If SmartScreen warns about the unsigned installer, choose **More info → Run anyway**. Uninstall from **Settings → Apps** or Arcade Tools.

### macOS

Open the dmg and drag Clipboard to Applications. If you run it from the dmg or Downloads, Clipboard offers to move itself to Applications. The app is not notarized, so right-click it and choose **Open** the first time.

### iPhone and iPad

The iOS app is distributed as an unsigned IPA that you must sign and install with your own signing tool. Follow the [iPhone setup guide](https://github.com/qa-p1/Arcade-clipboard/blob/main/docs/dev/ios.md).

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
