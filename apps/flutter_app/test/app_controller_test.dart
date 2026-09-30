import 'dart:async';
import 'dart:io';

import 'package:arcade_clipboard/models.dart';
import 'package:arcade_clipboard/platform/desktop_adapter.dart';
import 'package:arcade_clipboard/services/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_fakes/fake_core_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('onboarding validates a name, then creates and loads a mesh', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);

    expect(fixture.controller.ready, isTrue);
    expect(fixture.controller.hasMesh, isFalse);

    await fixture.controller.createMesh('   ');
    expect(fixture.controller.error, 'Add a name for this device.');
    expect(fixture.core.calls.where((call) => call.operation == 'create_mesh'), isEmpty);

    await fixture.controller.createMesh('Studio laptop');
    expect(fixture.controller.hasMesh, isTrue);
    expect(fixture.controller.status?.deviceName, 'Studio laptop');
    expect(fixture.controller.error, isNull);
  });

  test('automatic desktop capture is opt-in on startup', () async {
    final fixture = await _Fixture.create(hasMesh: true);
    addTearDown(fixture.dispose);

    expect(fixture.controller.automaticDesktopCapture, isFalse);
    expect(fixture.core.calls.where((call) => call.operation == 'capture'), isEmpty);
  });

  test('device models preserve the owner role from the core API', () {
    final owner = MeshDevice.fromJson({
      'device_id': 'owner-id',
      'device_name': 'Owner',
      'platform': 'Device',
      'state': 'online',
      'is_owner': true,
    });
    final member = MeshDevice.fromJson({
      'device_id': 'member-id',
      'device_name': 'Phone',
      'platform': 'Device',
      'state': 'offline',
      'is_owner': false,
    });

    expect(owner.isOwner, isTrue);
    expect(member.isOwner, isFalse);
  });

  test('the local owner manages peers without being counted as a paired device', () async {
    final fixture = await _Fixture.create(hasMesh: true);
    addTearDown(fixture.dispose);

    expect(fixture.controller.canManageDevices, isTrue);
    expect(fixture.controller.devices, isEmpty);
  });

  test('pairing requests arrive through revision changes and expired requests are hidden', () async {
    final fixture = await _Fixture.create(hasMesh: true);
    addTearDown(fixture.dispose);

    final now = DateTime.now().millisecondsSinceEpoch;
    fixture.core.setPendingPairings([
      {
        'session_id': 'active-session',
        'peer_name': 'Phone',
        'verification_code': '123 456',
        'expires_at': now + 60 * 1000,
        'direction': 'inbound',
        'state': 'awaiting_confirmation',
      },
      {
        'session_id': 'expired-session',
        'peer_name': 'Old phone',
        'verification_code': '000 000',
        'expires_at': now - 1,
        'direction': 'inbound',
        'state': 'awaiting_confirmation',
      },
    ]);
    fixture.core.signalChange(revision: 2);
    await Future<void>.delayed(Duration.zero);

    expect(fixture.controller.pairings.map((pairing) => pairing.sessionId), ['active-session']);
  });

  test('outbound verification follows pending pairing status and clears when it ends', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);

    await fixture.controller.joinMesh(invite: 'test-invite', deviceName: 'Phone');
    expect(fixture.controller.currentJoin?.sessionId, 'outbound-session');

    fixture.core.setPendingPairings([]);
    await fixture.controller.refreshStatus();

    expect(fixture.controller.currentJoin, isNull);
    expect(fixture.controller.notice, contains('request ended'));
  });

  test('later history searches win when an older request completes last', () async {
    final fixture = await _Fixture.create(hasMesh: true);
    addTearDown(fixture.dispose);
    final slow = Completer<Map<String, dynamic>>();
    final fast = Completer<Map<String, dynamic>>();
    fixture.core.historyReplies['slow'] = () => slow.future;
    fixture.core.historyReplies['fast'] = () => fast.future;

    final slowRequest = fixture.controller.refreshHistory(query: 'slow');
    final fastRequest = fixture.controller.refreshHistory(query: 'fast');
    fast.complete({'items': [_historyItem('fast', 'fast result')]});
    await fastRequest;
    slow.complete({'items': [_historyItem('slow', 'stale result')]});
    await slowRequest;

    expect(fixture.controller.query, 'fast');
    expect(fixture.controller.items.map((item) => item.id), ['fast']);
    expect(fixture.controller.historyLoading, isFalse);
  });

  test('core failures stay visible and can be cleared by a successful action', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    fixture.core.failures['create_mesh'] = StateError('secure keyring is locked');

    await fixture.controller.createMesh('Laptop');
    expect(fixture.controller.error, contains('secure key store is unavailable'));
    expect(fixture.controller.hasMesh, isFalse);

    fixture.core.failures.remove('create_mesh');
    await fixture.controller.createMesh('Laptop');
    expect(fixture.controller.hasMesh, isTrue);
    expect(fixture.controller.error, isNull);
  });

  test('settings update privacy, retention, and appearance state', () async {
    final fixture = await _Fixture.create(hasMesh: true);
    addTearDown(fixture.dispose);

    await fixture.controller.setPrivatePause(true);
    expect(fixture.controller.status?.paused, isTrue);

    await fixture.controller.setRetentionHours(168);
    expect(fixture.controller.retentionHours, 168);

    await fixture.controller.setRetentionHours(0);
    expect(fixture.controller.retentionHours, 168);
    expect(fixture.controller.error, 'Choose a supported history retention period.');

    await fixture.controller.setThemeMode(ThemeMode.dark);
    expect(fixture.controller.themeMode, ThemeMode.dark);
  });

  test('history and keyboard payloads honor Unix-millisecond expiry', () {
    final now = DateTime.now();
    final expiresAt = now.add(const Duration(minutes: 2));
    final item = ClipboardItem.fromJson({
      'id': 'clip-1',
      'origin_device': 'device-1',
      'source_name': 'Laptop',
      'created_at': now.millisecondsSinceEpoch,
      'expires_at': expiresAt.millisecondsSinceEpoch,
      'text': 'hello',
      'kind': 'text',
      'pinned': false,
    });

    expect(item.expiresAt, DateTime.fromMillisecondsSinceEpoch(expiresAt.millisecondsSinceEpoch));
    expect(item.isExpiredAt(now), isFalse);
    expect(item.toKeyboardJson()['expires_at'], expiresAt.millisecondsSinceEpoch);
    expect(
      ClipboardItem.fromJson({
        'id': 'clip-2',
        'created_at': now.millisecondsSinceEpoch,
        'expires_at': (now.millisecondsSinceEpoch - 1).toString(),
        'text': 'stale',
        'kind': 'text',
        'pinned': false,
      }).isExpiredAt(now),
      isTrue,
    );
  });
}

Map<String, dynamic> _historyItem(String id, String text) => {
      'id': id,
      'origin_device': 'device-1',
      'source_name': 'Laptop',
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'expires_at': DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
      'text': text,
      'kind': 'text',
      'pinned': false,
    };

class _Fixture {
  _Fixture(this.controller, this.core, this.directory);

  final AppController controller;
  final FakeCoreApi core;
  final Directory directory;

  static Future<_Fixture> create({bool hasMesh = false}) async {
    final directory = await Directory.systemTemp.createTemp('arcade-controller-test-');
    final core = FakeCoreApi(hasMesh: hasMesh);
    final controller = AppController(
      core: core,
      desktop: _TestDesktopAdapter(),
      dataDirectory: directory,
    );
    await controller.start();
    return _Fixture(controller, core, directory);
  }

  Future<void> dispose() async {
    controller.dispose();
    await directory.delete(recursive: true);
  }
}

class _TestDesktopAdapter extends DesktopAdapter {
  @override
  Future<DesktopCapabilities> initialize({
    required Future<void> Function(String text) onTextCaptured,
    required Future<void> Function() onOverlayRequested,
  }) async =>
      DesktopCapabilities(
        platform: 'test',
        clipboardCapture: false,
        globalShortcut: false,
        overlay: true,
        paste: false,
        copyFallback: true,
        detail: 'Test desktop adapter.',
      );

  @override
  Future<void> dispose() async {}
}
