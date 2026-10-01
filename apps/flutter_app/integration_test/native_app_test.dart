import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:arcade_clipboard/app.dart';
import 'package:arcade_clipboard/services/app_controller.dart';
import 'package:arcade_clipboard/services/core_api.dart';
import 'package:arcade_desktop_bridge/arcade_desktop_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'real secure pairing, remote history, native focus and Enter paste',
      (tester) async {
    final support = Platform.environment['ARCADE_DATA_DIR'];
    final driver = Platform.environment['ARCADE_TEST_DRIVER'];
    final target = Platform.environment['ARCADE_PASTE_TEST_TARGET'];
    expect(support, isNotNull, reason: 'Run scripts/test-native-linux.sh');
    expect(driver, isNotNull);
    expect(target, isNotNull);
    final boundary = GlobalKey();
    final core = RustCoreApi();
    final controller =
        AppController(core: core, dataDirectory: Directory(support!));
    final bridge = ArcadeDesktopBridge();
    Map<String, Object?>? previousClipboard;
    _Peer? peer;
    Process? editor;
    try {
      await tester.pumpWidget(RepaintBoundary(
          key: boundary, child: ArcadeApp(controller: controller)));
      await controller.start();
      await tester.pumpAndSettle();
      expect(controller.ready, isTrue, reason: controller.error);
      expect(find.text('Set up Arcade Clipboard'), findsOneWidget);
      await tester.tap(find.text('Create mesh'));
      await tester.pumpAndSettle();
      expect(controller.hasMesh, isTrue, reason: controller.error);
      expect(find.text('Your clipboard is empty'), findsOneWidget);
      previousClipboard = await bridge.readClipboard();
      const localSentinel = 'Local clipboard remains unchanged';
      await Clipboard.setData(const ClipboardData(text: localSentinel));
      await controller.createInvite();
      peer = await _Peer.start(driver!, '$support-peer');
      await peer.call('join', {
        'invite': controller.invite!.invite,
        'device_name': 'Acceptance peer',
      });
      await _eventually(() async {
        await controller.refreshStatus();
        return controller.pairings.isNotEmpty;
      });
      final remoteStatus = await peer.call('status');
      final remotePairing =
          (remoteStatus['pending_pairings'] as List).first as Map;
      expect(remotePairing['verification_code'],
          controller.pairings.first.verificationCode);
      await controller.confirmPairing(controller.pairings.first.sessionId,
          accept: true);
      await peer.call('confirm_pairing', {
        'session_id': remotePairing['session_id'],
        'accept': true,
      });
      await _eventually(
          () async => (await peer!.call('status'))['mesh_id'] != null);
      const sample = 'Native paste acceptance ✓';
      await peer.call('capture', {'text': sample});
      await _eventually(() async {
        await controller.refreshHistory();
        return controller.items.any((item) => item.text == sample);
      });
      // Remote delivery must leave the existing OS clipboard alone.
      expect(
          (await Clipboard.getData(Clipboard.kTextPlain))?.text, localSentinel);
      final received =
          controller.items.singleWhere((item) => item.text == sample);
      await controller.setPinned(received, true);
      await _eventually(() async => controller.items
          .any((item) => item.id == received.id && item.pinned));
      expect(
          controller.items.singleWhere((item) => item.id == received.id).pinned,
          isTrue);
      await controller.refreshHistory(query: 'acceptance');
      await _eventually(() async => !controller.historyLoading);
      expect(controller.items.length, 1);
      await controller.refreshHistory();
      await tester.pumpAndSettle();
      await _screenshot(boundary, 'native-history.png');

      final output = File('$support/pasted.txt');
      editor = await Process.start(target!, [output.path]);
      await _eventually(() async {
        final result = await Process.run('hyprctl', ['clients', '-j']);
        final clients = jsonDecode(result.stdout as String) as List;
        final matches = clients.where((value) => value['pid'] == editor!.pid);
        if (matches.isEmpty) return false;
        final status = await Process.run('hyprctl', ['-j', 'status']);
        final lua = status.exitCode == 0 &&
            (jsonDecode(status.stdout as String) as Map)['configProvider'] ==
                'lua';
        final address = matches.first['address'] as String;
        if (!RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(address)) return false;
        final focus = await Process.run(
            'hyprctl',
            lua
                ? [
                    'eval',
                    'hl.dispatch(hl.dsp.focus({ window = "address:$address" }))'
                  ]
                : ['dispatch', 'focuswindow', 'address:$address']);
        return focus.exitCode == 0;
      });
      await controller.openOverlay();
      await tester.pumpAndSettle();
      expect(controller.overlayOpen, isTrue, reason: controller.error);
      expect(find.text('Mesh Clipboard'), findsOneWidget);
      await _screenshot(boundary, 'native-overlay.png');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await _eventually(() async =>
          await output.exists() && await output.readAsString() == sample);
      expect(controller.overlayOpen, isFalse);
      expect(controller.items.where((item) => item.text == sample).length, 1);
      final remoteHistory = await peer.call('history', {'limit': 100});
      expect(
          (remoteHistory['items'] as List)
              .where((item) => item['text'] == sample)
              .length,
          1);
      expect(tester.takeException(), isNull);
    } finally {
      if (previousClipboard != null) {
        final formats = (previousClipboard['formats'] as List?)
                ?.map((value) => Map<String, Object?>.from(value as Map))
                .toList() ??
            [];
        final files =
            (previousClipboard['files'] as List?)?.cast<String>() ?? [];
        if (formats.isNotEmpty || files.isNotEmpty) {
          await bridge.writeClipboard(formats: formats, files: files);
        } else {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      }
      editor?.kill();
      await peer?.close();
      await tester.pumpWidget(const SizedBox.shrink());
      await core.invoke('shutdown');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _eventually(Future<bool> Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Native acceptance condition did not complete within 25 seconds.');
}

Future<void> _screenshot(GlobalKey key, String name) async {
  final directory = Platform.environment['ARCADE_SCREENSHOT_DIR'];
  if (directory == null) return;
  final render =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await render.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await Directory(directory).create(recursive: true);
  await File('$directory/$name').writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
}

class _Peer {
  _Peer(this.process)
      : lines = StreamIterator(process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter()));
  final Process process;
  final StreamIterator<String> lines;
  static Future<_Peer> start(String binary, String directory) async {
    final peer = _Peer(await Process.start(binary, []));
    peer.process.stderr.drain<void>();
    await peer.call('initialize',
        {'data_dir': directory, 'device_name': 'Acceptance peer'});
    return peer;
  }

  Future<Map<String, dynamic>> call(String op,
      [Map<String, Object?> arguments = const {}]) async {
    process.stdin.writeln(jsonEncode({'op': op, ...arguments}));
    await process.stdin.flush();
    if (!await lines.moveNext().timeout(const Duration(seconds: 30))) {
      throw StateError('Peer process exited.');
    }
    final response = jsonDecode(lines.current) as Map<String, dynamic>;
    if (response['error'] != null) {
      throw StateError('$op: ${response['error']}');
    }
    return Map<String, dynamic>.from(response['ok'] as Map);
  }

  Future<void> close() async {
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      process.kill();
      return -1;
    });
    await lines.cancel();
  }
}
