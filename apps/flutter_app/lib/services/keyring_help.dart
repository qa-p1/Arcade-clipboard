/// What to tell someone whose system key store refused Clipboard's device key.
///
/// Sync keeps each device's identity key in the operating system's key store,
/// never in a plain file, so a missing or locked store blocks setup. The
/// message says which case it is and what to do on this desktop.
library;

/// Whether [message] (a core error, lower-cased or not) is about the system key
/// store.
bool isKeyStoreError(String message) {
  final m = message.toLowerCase();
  return m.contains('keychain') ||
      m.contains('keystore') ||
      m.contains('secret service') ||
      m.contains('org.freedesktop.secrets') ||
      m.contains('keyring') ||
      m.contains('credential store') ||
      m.contains('secure store');
}

/// The message for a key store [error] on [os] (`linux`, `macos`, `windows`,
/// as `Platform.operatingSystem` names them). [desktop] is
/// `XDG_CURRENT_DESKTOP` on Linux.
String keyStoreHelp(String error, {required String os, String? desktop}) {
  final locked = error.toLowerCase().contains('locked');
  switch (os) {
    case 'macos':
      return locked
          ? 'Your login keychain is locked. Unlock it in Keychain Access, then try again.'
          : "Clipboard couldn't use your login keychain. Open Keychain Access, check that the login keychain "
              'exists and is unlocked, then try again.';
    case 'windows':
      return "Clipboard couldn't use Windows Credential Manager. Sign out and back in, then try again.";
    case 'linux':
      if (locked) {
        return 'Your system keyring is locked. Unlock it (signing out and back in usually does), then try again.';
      }
      return 'Sync keeps this device\'s key in your system keyring, and none is running. '
          'Install ${_linuxKeyring(desktop)}, sign out and back in, then try again.';
    default:
      return 'The secure key store is unavailable. Unlock or set up your system keyring, then try again.';
  }
}

String _linuxKeyring(String? desktop) {
  final names = (desktop ?? '')
      .toLowerCase()
      .split(':')
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toSet();
  if (names.contains('kde')) {
    return 'KDE Wallet (kwalletmanager) and turn on its Secret Service option, or GNOME Keyring (gnome-keyring)';
  }
  const gnomeFamily = {
    'gnome',
    'unity',
    'ubuntu',
    'pop',
    'cosmic',
    'x-cinnamon',
    'cinnamon',
    'mate',
    'xfce',
    'budgie',
    'budgie-desktop',
    'pantheon',
    'lxqt',
    'lxde',
  };
  if (names.any(gnomeFamily.contains)) {
    return 'GNOME Keyring (the gnome-keyring package)';
  }
  // Tiling compositors and window managers start nothing on their own.
  return 'GNOME Keyring (gnome-keyring) and start it with your session, or KeePassXC with its Secret Service '
      'integration on';
}
