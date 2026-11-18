import 'dart:convert';
import 'dart:io';

import 'package:arcade_clipboard/platform/wayland_clipboard.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for wl-paste: `--list-types` prints [types]; reading a type
/// prints "clip text" and records that it was read in [log].
Future<(String, File)> _fakeWlPaste(
    Directory folder, List<String> types) async {
  final log = File('${folder.path}/reads.log');
  final script = File('${folder.path}/wl-paste');
  await script.writeAsString('''#!/bin/sh
if [ "\$1" = "--list-types" ]; then
cat <<'TYPES'
${types.join('\n')}
TYPES
exit 0
fi
echo "\$@" >> '${log.path}'
printf 'clip text'
''');
  await Process.run('chmod', ['755', script.path]);
  return (script.path, log);
}

void main() {
  test('a password manager hint returns no formats and is never read',
      () async {
    final folder = await Directory.systemTemp.createTemp('wl-paste-test');
    addTearDown(() => folder.delete(recursive: true));
    for (final hint in const [
      'x-kde-passwordManagerHint',
      'X-KDE-PASSWORDMANAGERHINT',
      'application/x-keepassxc-clipboard',
    ]) {
      final (wlPaste, log) =
          await _fakeWlPaste(folder, ['text/plain;charset=utf-8', hint]);
      if (log.existsSync()) log.deleteSync();
      final result = await readWaylandClipboard(wlPaste);
      expect(result['sensitive'], isTrue, reason: hint);
      expect(result['formats'], isEmpty, reason: hint);
      expect(log.existsSync(), isFalse, reason: 'no content read for $hint');
    }
  });

  test('an ordinary selection is read, and is not marked sensitive', () async {
    final folder = await Directory.systemTemp.createTemp('wl-paste-test');
    addTearDown(() => folder.delete(recursive: true));
    final (wlPaste, _) =
        await _fakeWlPaste(folder, ['text/plain;charset=utf-8', 'TEXT']);
    final result = await readWaylandClipboard(wlPaste);
    expect(result['sensitive'], isFalse);
    final formats = result['formats'] as List;
    expect(formats, hasLength(1));
    expect((formats.single as Map)['mimeType'], 'text/plain');
    expect(utf8.decode((formats.single as Map)['bytes'] as List<int>),
        'clip text');
  });
}
