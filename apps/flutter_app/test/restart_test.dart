import 'dart:io';

import 'package:arcade_clipboard/platform/desktop_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CB-4: restart re-executes the AppImage file, not the mounted binary',
      () async {
    final dir = await Directory.systemTemp.createTemp('restart-test-');
    addTearDown(() => dir.delete(recursive: true));
    final image = File('${dir.path}/Arcade-Clipboard.AppImage')
      ..writeAsStringSync('x');
    const mounted = '/tmp/.mount_abc/usr/lib/arcade-clipboard/clipboard';
    expect(
        DesktopAdapter.restartExecutable(
            {'APPIMAGE': image.path}, mounted, File.new),
        image.path);
    // Outside an AppImage, or when the image is gone, the binary is used.
    expect(DesktopAdapter.restartExecutable({}, mounted, File.new), mounted);
    expect(
        DesktopAdapter.restartExecutable(
            {'APPIMAGE': '${dir.path}/missing'}, mounted, File.new),
        mounted);
  });

  test('restart from the unpacked copy starts the successor as a fresh start',
      () {
    const copy =
        '/home/u/.local/share/arcade/runtime/clipboard-0.3.2-0123456789abcdef/usr/lib/arcade-clipboard/clipboard';
    const mounted = '/tmp/.mount_abc/usr/lib/arcade-clipboard/clipboard';
    final parent = {
      'HOME': '/home/u',
      'APPIMAGE': '/home/u/Applications/Arcade/Arcade-Clipboard.AppImage',
      'ARCADE_UNPACKED': '1',
    };
    // In the copy the marker is dropped (the successor must unpack again) and
    // the old process id is added; nothing else changes.
    expect(DesktopAdapter.successorEnvironment(parent, copy, 42), {
      'HOME': '/home/u',
      'APPIMAGE': '/home/u/Applications/Arcade/Arcade-Clipboard.AppImage',
      DesktopAdapter.restartEnvironment: '42',
    });
    // Anywhere else (the mount, a bundle, a harness that set it) it stays.
    expect(
        DesktopAdapter.successorEnvironment(
            parent, mounted, 42)['ARCADE_UNPACKED'],
        '1');
    expect(DesktopAdapter.successorEnvironment({'A': 'b'}, copy, 7),
        {'A': 'b', DesktopAdapter.restartEnvironment: '7'});
  });
}
