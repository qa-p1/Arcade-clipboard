import 'package:arcade_clipboard/services/desktop_commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('status, help and restart answer without opening the app', () {
    for (final flag in [
      '--status',
      '--help',
      '-h',
      '--restart',
      '--version',
      '--quit'
    ]) {
      expect(isHeadlessCommand([flag], isMacOS: false), isTrue, reason: flag);
    }
    expect(isHeadlessCommand(['--show'], isMacOS: false), isFalse);
    expect(isHeadlessCommand(['--install'], isMacOS: false), isFalse);
    expect(isHeadlessCommand(['--install'], isMacOS: true), isTrue);
  });

  test('a second launch asks the running copy for the matching surface', () {
    expect(runningInstanceRequest([])?.method, 'app.activate');
    expect(runningInstanceRequest(['--show'])?.method, 'app.activate');
    expect(runningInstanceRequest(['--settings'])?.method, 'app.settings');
    for (final (flag, id) in [
      ('--overlay', 'cli.overlay'),
      ('--hide', 'cli.hide'),
      ('--toggle', 'cli.toggle')
    ]) {
      final request = runningInstanceRequest([flag])!;
      expect((request.method, request.params['id']), ('app.menu.invoke', id),
          reason: flag);
    }
    // A login start never pops the window of an app that already runs.
    expect(runningInstanceRequest(['--background']), isNull);
  });
}
