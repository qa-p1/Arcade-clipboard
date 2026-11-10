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
}
