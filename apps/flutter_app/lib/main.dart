import 'dart:convert';
import 'dart:io';

import 'package:arcade_desktop_bridge/arcade_desktop_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'platform/desktop_adapter.dart';
import 'services/app_controller.dart';
import 'services/app_settings.dart';
import 'services/core_api.dart';
import 'services/desktop_commands.dart';

void main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  await _waitForPredecessor();
  // The standard Arcade flags answer and exit without opening any UI.
  if (isHeadlessCommand(arguments, isMacOS: Platform.isMacOS)) {
    exit(await _command(arguments));
  }
  // Single instance (STANDARD §10): a second launch hands its request to the
  // running copy over the Link and exits. A unique Linux instance forwards
  // natively before Dart runs; development profiles (ARCADE_DATA_DIR) and
  // Windows and macOS get here.
  if ((Platform.isLinux || Platform.isWindows || Platform.isMacOS) &&
      await _forwardedToRunning(arguments)) {
    exit(0);
  }
  runApp(ArcadeApp(
      controller: AppController(
          startInBackground: arguments.contains('--background') ||
              arguments.contains('--overlay'),
          openOverlayOnStart: arguments.contains('--overlay'),
          openSettingsOnStart: arguments.contains('--settings'))));
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

/// Prints a command's answer. For `--version` and `--arcade-manifest` the
/// Linux runner moves engine logging off stdout (ARCADE_ANSWER_FD names the
/// saved real stdout) and writes the answer there itself.
Future<void> _answer(String text) async {
  if (Platform.isLinux && Platform.environment['ARCADE_ANSWER_FD'] != null) {
    await const MethodChannel('arcade_clipboard/answer')
        .invokeMethod<void>('write', text);
    return;
  }
  stdout.write(text);
  await stdout.flush();
}

Future<bool> _forwardedToRunning(List<String> arguments) async {
  final running = await RustCoreApi()
      .invoke('link_status')
      .catchError((Object _) => <String, dynamic>{});
  if (running['running'] != true) return arguments.contains('--hide');
  final request = runningInstanceRequest(arguments);
  if (request == null) return true;
  final answer = await RustCoreApi().invoke('link_call_running', {
    'method': request.method,
    'params': request.params
  }).catchError((Object _) => <String, dynamic>{});
  return answer['answered'] == true;
}

Future<int> _command(List<String> arguments) async {
  final core = RustCoreApi();
  final out = StringBuffer();
  try {
    if (arguments.contains('--help') || arguments.contains('-h')) {
      out.write(desktopUsage);
    } else if (arguments.contains('--status')) {
      out.writeln(jsonEncode(await core.invoke('link_status')));
    } else if (arguments.contains('--restart')) {
      final answer = await core.invoke('link_call_running', {
        'method': 'app.restart',
        'params': {'mode': 'normal'},
      });
      if (answer['answered'] != true) {
        throw StateError("Arcade Clipboard isn't running.");
      }
    } else if (arguments.contains('--version')) {
      final version = await core.invoke('version');
      out.writeln('Arcade Clipboard ${version['version']}');
    } else if (arguments.contains('--arcade-manifest')) {
      final override = Platform.environment['ARCADE_DATA_DIR']?.trim() ?? '';
      await useArcadeFolders(() => core.invoke('app_dirs'),
          override: override.isNotEmpty
              ? override
              : const String.fromEnvironment('ARCADE_DATA_DIR').trim());
      final prefs = await AppSettings.instance();
      final manifest = await core.invoke('link_manifest', {
        'link': {
          'enabled': prefs.getBool('link_enabled') ?? true,
          'disabled_peers': prefs.getStringList('link_disabled_peers') ?? [],
          'shortcut': prefs.getString('mesh_shortcut') ??
              DesktopAdapter.defaultShortcut,
        },
      });
      out.writeln(const JsonEncoder.withIndent('  ').convert(manifest));
    } else if (arguments.contains('--integration-status')) {
      final status = await core.invoke('install_status');
      out.writeln(const JsonEncoder.withIndent('  ').convert(status));
    } else if (Platform.isMacOS &&
        arguments
            .any(const {'--install', '--uninstall', '--repair'}.contains)) {
      final installed = await runMacosInstallCommand(arguments,
          core: core, bridge: ArcadeDesktopBridge());
      out.writeln(const JsonEncoder.withIndent('  ').convert(installed));
      if (arguments.contains('--install') &&
          !arguments.contains('--no-launch')) {
        final result =
            await Process.run('/usr/bin/open', [installed['launch'] as String]);
        if (result.exitCode != 0) {
          throw StateError("Couldn't open the installed app: ${result.stderr}");
        }
      }
    } else {
      // The desktop single-instance channel (Linux D-Bus) handles --quit
      // before Dart runs when it can; this covers the rest over the Link.
      await core.invoke('link_quit_running');
    }
    await _answer(out.toString());
    return 0;
  } catch (error) {
    stderr.writeln('Arcade Clipboard: $error');
    return 1;
  }
}
