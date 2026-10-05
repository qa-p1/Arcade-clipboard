import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:arcade_clipboard/app.dart';
import 'package:arcade_clipboard/platform/desktop_adapter.dart';
import 'package:arcade_clipboard/services/app_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_fakes/fake_core_api.dart';

// These screenshots exercise the production widgets using test-only history.
// They are review artifacts rather than pixel goldens tied to one host font.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final inter = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
    await inter.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('capture desktop history, dark appearance, and compact overlay',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1240, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = (await tester.runAsync(() => _Fixture.create()))!;
    addTearDown(fixture.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundary, child: ArcadeApp(controller: fixture.controller)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, boundary, 'desktop-clipboard-light.png');

    await fixture.controller.setThemeMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, boundary, 'desktop-clipboard-dark.png');

    await fixture.controller.openOverlay();
    await tester.binding.setSurfaceSize(const Size(430, 510));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, boundary, 'desktop-overlay-dark.png');
    await fixture.controller.setThemeMode(ThemeMode.light);
    await tester.pumpAndSettle();
    await _capture(tester, boundary, 'desktop-overlay-light.png');
  });

  testWidgets('capture mobile history and settings without layout overflow',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final fixture =
        (await tester.runAsync(() => _Fixture.create(mobile: true)))!;
    addTearDown(fixture.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundary, child: ArcadeApp(controller: fixture.controller)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, boundary, 'mobile-clipboard-light.png');

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, boundary, 'mobile-settings-light.png');
    await fixture.controller.setThemeMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, boundary, 'mobile-settings-dark.png');
    debugDefaultTargetPlatformOverride = null;
  });
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory(
        '${Directory.current.parent.parent.path}/.verification/screenshots');
    await directory.create(recursive: true);
    await File('${directory.path}/$name')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

class _Fixture {
  _Fixture(this.controller, this.directory);
  final AppController controller;
  final Directory directory;

  static Future<_Fixture> create({bool mobile = false}) async {
    final directory = await Directory.systemTemp.createTemp('arcade-visual-');
    final core = FakeCoreApi(hasMesh: true);
    await core.invoke('create_mesh', {'device_name': 'Work laptop'});
    final now = DateTime.now();
    final image = await _exampleImage();
    core.historyItems.addAll([
      _clip(
          'review',
          'Weekly review\n• Update the release notes\n• Check the Android share flow\n• Review the pairing screens',
          now.subtract(const Duration(minutes: 4)),
          pinned: true),
      _clip('link', 'https://docs.flutter.dev/platform-integration/desktop',
          now.subtract(const Duration(seconds: 24)),
          kind: 'url', source: 'Phone'),
      _clip('command', 'cargo test --workspace',
          now.subtract(const Duration(minutes: 2))),
      {
        ..._clip('image', '', now.subtract(const Duration(minutes: 3)),
            kind: 'image', source: 'Phone'),
        'preview': 'Layout notes.png',
        'size': image.length,
        'representations': [
          {
            'mime_type': 'image/png',
            'name': 'Layout notes.png',
            'data_base64': base64Encode(image)
          }
        ]
      },
      _clip(
          'note',
          'The new clipboard picker keeps the newest clip selected. Enter pastes it into the app you were using.',
          now.subtract(const Duration(minutes: 8)),
          source: 'Home desktop'),
      {
        ..._clip('file', '', now.subtract(const Duration(minutes: 12)),
            kind: 'file', source: 'Home desktop'),
        'preview': 'Release checklist.txt',
        'size': 1280,
        'representations': [
          {
            'mime_type': 'text/plain',
            'name': 'Release checklist.txt',
            'data_base64': base64Encode(utf8
                .encode('Review pairing, sharing, and keyboard navigation.'))
          }
        ]
      },
    ]);
    final controller = mobile
        ? _MobileController(
            core: core, desktop: _Desktop(), dataDirectory: directory)
        : AppController(
            core: core, desktop: _Desktop(), dataDirectory: directory);
    await controller.start();
    controller.dismissNotice();
    return _Fixture(controller, directory);
  }

  Future<void> dispose() async => directory.delete(recursive: true);
}

Map<String, dynamic> _clip(String id, String text, DateTime time,
        {String kind = 'text',
        String source = 'Work laptop',
        bool pinned = false}) =>
    {
      'id': id,
      'origin_device': source == 'Work laptop' ? 'device-1' : source,
      'source_name': source,
      'created_at': time.millisecondsSinceEpoch,
      'expires_at': time.add(const Duration(days: 7)).millisecondsSinceEpoch,
      'text': text,
      'kind': kind,
      'pinned': pinned,
    };

Future<Uint8List> _exampleImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFF0EFE9), BlendMode.src);
  final paint = Paint()..color = const Color(0xFF386253);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(20, 20, 200, 120), const Radius.circular(12)),
      paint);
  paint.color = const Color(0xFFE6EDE5);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(36, 38, 74, 82), const Radius.circular(6)),
      paint);
  paint.color = const Color(0xFFB7C8B8);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(126, 38, 78, 15), const Radius.circular(3)),
      paint);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(126, 65, 54, 9), const Radius.circular(3)),
      paint);
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(126, 84, 64, 9), const Radius.circular(3)),
      paint);
  final picture = recorder.endRecording();
  final image = await picture.toImage(240, 160);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

class _MobileController extends AppController {
  _MobileController(
      {required super.core,
      required super.desktop,
      required super.dataDirectory});
  @override
  bool get desktopAvailable => false;
}

class _Desktop extends DesktopAdapter {
  @override
  Future<DesktopCapabilities> initialize(
          {required Future<void> Function(String text) onTextCaptured,
          required Future<void> Function() onOverlayRequested}) async =>
      DesktopCapabilities(
          platform: 'test',
          clipboardCapture: true,
          globalShortcut: true,
          overlay: true,
          paste: true,
          copyFallback: true,
          detail: '');
  @override
  Future<void> configureShortcut(String shortcut) async {}
  @override
  Future<void> setBackgroundEnabled(bool enabled) async {}
  @override
  Future<bool> launchAtLoginEnabled() async => false;
  @override
  Future<void> showOverlay({bool paste = true}) async {}
  @override
  Future<void> hideOverlay() async {}
  @override
  Future<void> dispose() async {}
}
