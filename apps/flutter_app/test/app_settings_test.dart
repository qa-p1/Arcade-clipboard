import 'dart:convert';
import 'dart:io';

import 'package:arcade_clipboard/services/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory home;
  setUp(() async =>
      home = await Directory.systemTemp.createTemp('arcade-settings-'));
  tearDown(() => home.delete(recursive: true));

  test('imports an older version\'s preferences once, then removes them',
      () async {
    final legacy = File('${home.path}/data/shared_preferences.json');
    await legacy.create(recursive: true);
    await legacy.writeAsString(jsonEncode({
      'flutter.device_name': 'Laptop',
      'flutter.mesh_shortcut': 'CTRL+SHIFT+SPACE',
      'flutter.link_enabled': false,
      'flutter.link_disabled_peers': ['arcade.box'],
      'other.key': 'not ours',
    }));
    final file = File('${home.path}/config/settings.json');

    final settings = await AppSettings.useFile(file, legacy: legacy);
    expect(settings.getString('device_name'), 'Laptop');
    expect(settings.getString('mesh_shortcut'), 'CTRL+SHIFT+SPACE');
    expect(settings.getBool('link_enabled'), isFalse);
    expect(settings.getStringList('link_disabled_peers'), ['arcade.box']);
    expect(settings.containsKey('other.key'), isFalse);
    expect(await legacy.exists(), isFalse,
        reason: 'removed only after the new file verified');

    await settings.setString('appearance_mode', 'dark');
    final reopened = await AppSettings.useFile(file, legacy: legacy);
    expect(reopened.getString('device_name'), 'Laptop');
    expect(reopened.getString('appearance_mode'), 'dark');
    expect(identical(await AppSettings.instance(), reopened), isTrue);
  });

  test('a new profile starts empty and a damaged file does not stop the app',
      () async {
    final file = File('${home.path}/config/settings.json');
    final fresh = await AppSettings.useFile(file,
        legacy: File('${home.path}/missing.json'));
    expect(fresh.containsKey('device_name'), isFalse);
    expect(jsonDecode(await file.readAsString()), isEmpty);

    await file.writeAsString('{not json');
    final damaged = await AppSettings.useFile(file);
    expect(damaged.getString('device_name'), isNull);
  });
}
