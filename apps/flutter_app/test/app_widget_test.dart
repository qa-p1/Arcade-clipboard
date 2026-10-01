import 'dart:io';

import 'package:arcade_clipboard/app.dart';
import 'package:arcade_clipboard/platform/desktop_adapter.dart';
import 'package:arcade_clipboard/services/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_fakes/fake_core_api.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'create a mesh, add a clip, inspect it, and filter pinned history',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1180, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = (await tester.runAsync(() => _Fixture.create()))!;
    addTearDown(fixture.dispose);
    await tester.pumpWidget(ArcadeApp(controller: fixture.controller));
    await tester.pumpAndSettle();

    expect(find.text('Set up Arcade Clipboard'), findsOneWidget);
    await tester.tap(find.text('Create mesh'));
    await tester.pumpAndSettle();
    expect(find.text('Your clipboard is empty'), findsOneWidget);

    await tester.tap(find.text('Add clip'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).last, 'Meeting notes for tomorrow');
    await tester.tap(find.widgetWithText(FilledButton, 'Add clip').last);
    await tester.pumpAndSettle();
    expect(find.text('Meeting notes for tomorrow'), findsOneWidget);

    await tester.tap(find.text('Meeting notes for tomorrow'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pinned'));
    await tester.pumpAndSettle();
    expect(find.text('No matching clips'), findsOneWidget);
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('Meeting notes for tomorrow'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'settings and clipboard remain usable on a narrow window in both themes',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture =
        (await tester.runAsync(() => _Fixture.create(hasMesh: true)))!;
    addTearDown(fixture.dispose);
    await tester.pumpWidget(ArcadeApp(controller: fixture.controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    expect(find.text('Private mode'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await fixture.controller.setThemeMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(find.text('Theme'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'owner can approve a pairing request without closing its QR dialog',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1180, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture =
        (await tester.runAsync(() => _Fixture.create(hasMesh: true)))!;
    addTearDown(fixture.dispose);
    await tester.pumpWidget(ArcadeApp(controller: fixture.controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Devices').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add device').first);
    await tester.pumpAndSettle();

    fixture.core.setPendingPairings([
      {
        'session_id': 'phone-session',
        'peer_name': 'Phone',
        'verification_code': '628 140',
        'expires_at': DateTime.now()
            .add(const Duration(minutes: 2))
            .millisecondsSinceEpoch,
        'direction': 'inbound',
        'state': 'awaiting_confirmation',
      }
    ]);
    await fixture.controller.refreshStatus();
    await tester.pumpAndSettle();
    expect(find.text('628 140'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, 'Approve').last);
    await tester.pumpAndSettle();
    expect(
        fixture.core.calls.any((call) =>
            call.operation == 'confirm_pairing' &&
            call.arguments['session_id'] == 'phone-session' &&
            call.arguments['accept'] == true),
        isTrue);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'overlay supports arrow, Home, End, Enter, and Escape while search has focus',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 510));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture =
        (await tester.runAsync(() => _Fixture.create(hasMesh: true)))!;
    addTearDown(fixture.dispose);
    await fixture.controller.addText('First clip');
    await fixture.controller.addText('Second clip');
    final now = DateTime.now().millisecondsSinceEpoch;
    fixture.core.historyItems[0]['created_at'] = now - 1000;
    fixture.core.historyItems[1]['created_at'] = now;
    await fixture.controller.refreshHistory();
    await tester.pumpWidget(ArcadeApp(controller: fixture.controller));
    await fixture.controller.openOverlay();
    await tester.pumpAndSettle();

    expect(find.text('Mesh Clipboard'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fixture.desktop.pasted, 'First clip');
    expect(fixture.controller.overlayOpen, isFalse);

    await fixture.controller.openOverlay();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fixture.desktop.pasted, 'Second clip');

    await fixture.controller.openOverlay();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(fixture.controller.overlayOpen, isFalse);
    expect(tester.takeException(), isNull);
  });
}

class _Fixture {
  _Fixture(this.controller, this.core, this.desktop, this.directory);
  final AppController controller;
  final FakeCoreApi core;
  final _Desktop desktop;
  final Directory directory;

  static Future<_Fixture> create({bool hasMesh = false}) async {
    final directory = await Directory.systemTemp.createTemp('arcade-ui-test-');
    final core = FakeCoreApi(hasMesh: hasMesh);
    final desktop = _Desktop();
    final controller =
        AppController(core: core, desktop: desktop, dataDirectory: directory);
    await controller.start();
    return _Fixture(controller, core, desktop, directory);
  }

  Future<void> dispose() async => directory.delete(recursive: true);
}

class _Desktop extends DesktopAdapter {
  String? pasted;
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
  Future<void> setCaptureEnabled(bool enabled) async {}
  @override
  Future<void> setBackgroundEnabled(bool enabled) async {}
  @override
  Future<bool> launchAtLoginEnabled() async => false;
  @override
  Future<void> showOverlay() async {}
  @override
  Future<void> hideOverlay() async {}
  @override
  Future<void> pasteText(String text) async {
    pasted = text;
  }

  @override
  Future<void> dispose() async {}
}
