import 'package:arcade_clipboard/services/keyring_help.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('key store errors are recognised whatever the store is called', () {
    for (final message in [
      'Could not access the system credential store: no backend',
      'org.freedesktop.secrets was not provided by any .service files',
      'Secret Service: no result found',
      'secure keyring is locked',
      'User interaction is not allowed (keychain)',
      'Android Keystore failure',
    ]) {
      expect(isKeyStoreError(message), isTrue, reason: message);
    }
    expect(isKeyStoreError('Could not reach the mesh owner'), isFalse);
  });

  test('a locked keyring says to unlock it, not to install one', () {
    final text =
        keyStoreHelp('secure keyring is locked', os: 'linux', desktop: 'GNOME');
    expect(text, contains('locked'));
    expect(text, isNot(contains('Install')));
  });

  test('a missing keyring names what to install on this desktop', () {
    const error =
        'org.freedesktop.secrets was not provided by any .service files';
    expect(keyStoreHelp(error, os: 'linux', desktop: 'ubuntu:GNOME'),
        contains('gnome-keyring package'));
    expect(keyStoreHelp(error, os: 'linux', desktop: 'X-Cinnamon'),
        contains('gnome-keyring package'));
    expect(keyStoreHelp(error, os: 'linux', desktop: 'KDE'),
        contains('KDE Wallet'));
    final tiling = keyStoreHelp(error, os: 'linux', desktop: 'Hyprland');
    expect(tiling, contains('start it with your session'));
    expect(tiling, contains('KeePassXC'));
    expect(keyStoreHelp(error, os: 'linux'),
        contains('start it with your session'));
  });

  test('macOS and Windows name their own stores', () {
    expect(keyStoreHelp('keychain', os: 'macos'), contains('Keychain Access'));
    expect(keyStoreHelp('locked keychain', os: 'macos'), contains('is locked'));
    expect(keyStoreHelp('credential store', os: 'windows'),
        contains('Credential Manager'));
  });
}
