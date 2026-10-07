import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'platform/desktop_adapter.dart';
import 'services/app_controller.dart';
import 'services/core_api.dart';

void main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  await _waitForPredecessor();
  // The standard Arcade flags answer and exit without opening any UI.
  if (arguments.contains('--version') ||
      arguments.contains('--arcade-manifest') ||
      arguments.contains('--quit')) {
    exit(await _command(arguments));
  }
  runApp(ArcadeApp(
      controller: AppController(
          startInBackground: arguments.contains('--background') ||
              arguments.contains('--overlay'),
          openOverlayOnStart: arguments.contains('--overlay'))));
}

/// After the tray's Restart: waits (up to 5 s) for the old instance to exit.
/// Linux does this in the native runner, before its single-instance check.
Future<void> _waitForPredecessor() async {
  final old = int.tryParse(
      Platform.environment[DesktopAdapter.restartEnvironment] ?? '');
  if (old == null || Platform.isLinux) return;
  for (var attempt = 0; attempt < 50; attempt++) {
    if (!await _running(old)) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<bool> _running(int processId) async {
  try {
    if (Platform.isWindows) {
      final r = await Process.run(
          'tasklist', ['/FI', 'PID eq $processId', '/NH', '/FO', 'CSV']);
      return '${r.stdout}'.contains('"$processId"');
    }
    return (await Process.run('kill', ['-0', '$processId'])).exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<int> _command(List<String> arguments) async {
  final core = RustCoreApi();
  try {
    if (arguments.contains('--version')) {
      final version = await core.invoke('version');
      stdout.writeln('Arcade Clipboard ${version['version']}');
    } else if (arguments.contains('--arcade-manifest')) {
      final prefs = await SharedPreferences.getInstance();
      final manifest = await core.invoke('link_manifest', {
        'link': {
          'enabled': prefs.getBool('link_enabled') ?? true,
          'disabled_peers': prefs.getStringList('link_disabled_peers') ?? [],
          'shortcut': prefs.getString('mesh_shortcut') ?? _defaultShortcut(),
        },
      });
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(manifest));
    } else {
      // The desktop single-instance channel (Linux D-Bus) handles --quit
      // before Dart runs when it can; this covers the rest over the Link.
      await core.invoke('link_quit_running');
    }
    await stdout.flush();
    return 0;
  } catch (error) {
    stderr.writeln('Arcade Clipboard: $error');
    return 1;
  }
}

String _defaultShortcut() => switch (Platform.operatingSystem) {
      'macos' => 'CMD+SHIFT+V',
      'windows' => 'CTRL+ALT+V',
      _ => 'CTRL+SHIFT+SPACE',
    };
