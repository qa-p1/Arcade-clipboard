import 'dart:convert';
import 'dart:io';

import '../services/diagnostics.dart';
import 'desktop_adapter.dart'
    show DesktopIntegrationException, DesktopShortcut, isTerminalWindowClass;

/// Runs a desktop utility to completion. The adapter's runner applies a
/// timeout and reports failures in the result instead of throwing.
typedef CommandRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);

/// The Hyprland compositor, reached through `hyprctl`: the app's global
/// shortcut bind, the app to paste into, and the window helpers the picker
/// uses. Every command speaks Lua to compositors configured with Lua and the
/// older keyword and dispatch syntax to the rest.
class Hyprland {
  Hyprland(this._runCommand);

  final CommandRunner _runCommand;

  /// The app focused when the picker opened, which paste returns to.
  HyprlandTarget? target;

  _Binding? _binding;
  bool? _lua;
  final List<_Binding> _bindings = [];

  Future<void> ensurePickerRule(
      {required String title, required int width, required int height}) async {
    if (await _detectLua()) {
      final result = await _runCommand('hyprctl', [
        'eval',
        // The class is dev.arcade.Clipboard from 0.3.0 (STANDARD §10). The
        // guard is new too: a session that ran 0.2 already set the old one
        // for a rule matching the old class.
        'if not rawget(_G, "ARCADE_CLIPBOARD_PICKER_RULE_V2") then '
            'hl.window_rule({ match = { class = "^dev[.]arcade[.]Clipboard\$", title = "^$title\$" }, '
            'float = true, pin = true, center = true, size = "$width $height" }); '
            'rawset(_G, "ARCADE_CLIPBOARD_PICKER_RULE_V2", true) end'
      ]);
      if (result.exitCode != 0) {
        Diagnostics.log(
            'overlay', 'picker rule rejected: ${_processError(result)}');
      }
    }
  }

  Future<Map<String, Object?>?> ownWindow(String title) async {
    final result = await _runCommand('hyprctl', ['-j', 'clients']);
    if (result.exitCode != 0) return null;
    try {
      final clients = jsonDecode(result.stdout as String);
      if (clients is! List) return null;
      for (final client in clients) {
        if (client is Map &&
            client['pid'] == pid &&
            client['title'] == title &&
            client['address'] is String) {
          return {'address': client['address'], 'floating': client['floating']};
        }
      }
    } catch (_) {
      // Unreadable client list; placement falls back to the window rule.
    }
    return null;
  }

  Future<void> windowAction(String address, List<String> luaActions,
      {required List<List<String>> legacy}) async {
    if (!RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(address)) return;
    if (await _detectLua()) {
      final body =
          luaActions.map((action) => 'hl.dispatch($action)').join('; ');
      await _runCommand('hyprctl', [
        'eval',
        'local w = hl.get_window(${_luaString('address:$address')}); if w then $body end'
      ]);
      return;
    }
    for (final action in legacy) {
      await _runCommand('hyprctl', ['dispatch', action[0], action[1]]);
    }
  }

  Future<void> configureShortcut(DesktopShortcut shortcut) async {
    final lua = await _detectLua();
    var previous = _binding;
    if (previous != null) {
      final current = await _readBinds();
      final owned = previous;
      final present = current.any((bind) =>
          bind.modifierMask == owned.modifierMask &&
          bind.key.toUpperCase() == owned.key.toUpperCase() &&
          bind.argument.contains(owned.marker));
      if (!present) {
        // A compositor reload removes runtime binds and their Lua handles.
        _bindings.remove(previous);
        _binding = null;
        previous = null;
      } else if (previous.modifierMask == shortcut.hyprlandModifierMask &&
          previous.key.toUpperCase() == shortcut.hyprlandKey.toUpperCase() &&
          (previous.luaHandle != null) == lua) {
        return;
      }
    }

    // A prior failed rollback can leave an extra app-owned binding. Remove
    // those before starting another transaction, while retaining the binding
    // that is currently considered authoritative.
    for (final owned in List<_Binding>.of(_bindings)) {
      if (identical(owned, previous)) continue;
      await _unbind(owned);
      _bindings.remove(owned);
    }

    final binds = await _readBinds();
    await _removeStaleOwnedBinds(binds);
    final current = await _readBinds();
    final mask = shortcut.hyprlandModifierMask;
    final key = shortcut.hyprlandKey;
    final conflict = current.any((bind) {
      if (bind.modifierMask != mask ||
          bind.key.toUpperCase() != key.toUpperCase()) {
        return false;
      }
      return !_bindings.any((owned) =>
          owned.modifierMask == bind.modifierMask &&
          owned.key.toUpperCase() == bind.key.toUpperCase() &&
          bind.argument.contains(owned.marker));
    });
    if (conflict) {
      throw const DesktopIntegrationException(
          'That shortcut is already assigned in Hyprland. Choose another combination.');
    }

    final processId = pid;
    final startTicks = await _processStartTicks(processId);
    final marker = 'ACBMESH_SIGNAL_${processId}_$startTicks';
    // Hyprland dispatches this command through its session IPC. The shell
    // command includes a start-time guard so a stale bind cannot signal a
    // different process if Linux later reuses this PID.
    final command =
        'sh -c \': $marker; test "\$(sed "s/^.*) //" /proc/$processId/stat | cut -d" " -f20)" = "$startTicks" && kill -USR1 $processId\'';
    final value =
        '${shortcut.hyprlandModifiers},${shortcut.hyprlandKey},exec,$command';
    final luaHandle = lua ? _hyprlandHandle(marker, mask, key) : null;
    final chord = [...shortcut.hyprlandModifiers.split(' '), key].join(' + ');
    final result = await _runCommand(
        'hyprctl',
        lua
            ? [
                'eval',
                'local b = hl.bind(${_luaString(chord)}, hl.dsp.exec_cmd(${_luaString(command)}), { description = ${_luaString('Arcade Clipboard $marker')} }); '
                    'assert(b, "Hyprland rejected the shortcut"); _G[${_luaString(luaHandle!)}] = b'
              ]
            : ['keyword', 'bind', value]);
    _requireOk(result, "Couldn't register the Hyprland shortcut.");
    final replacement = _Binding(
      modifiers: shortcut.hyprlandModifiers,
      key: shortcut.hyprlandKey,
      modifierMask: mask,
      marker: marker,
      luaHandle: luaHandle,
    );
    _bindings.add(replacement);

    if (previous != null) {
      try {
        await _unbind(previous);
        _bindings.remove(previous);
      } catch (error) {
        try {
          await _unbind(replacement);
          _bindings.remove(replacement);
        } catch (rollbackError) {
          // Keep both references so dispose can retry cleanup. The old binding
          // remains authoritative; both commands carry PID/start-time guards.
          throw DesktopIntegrationException(
            "Couldn't remove the old shortcut after registering the new one, and undoing it failed too. "
            'The previous shortcut remains active. $error $rollbackError',
          );
        }
        throw DesktopIntegrationException(
          "Couldn't replace the previous shortcut. It stays active. $error",
        );
      }
    }
    _binding = replacement;
  }

  Future<void> removeShortcut() async {
    final bindings = List<_Binding>.of(_bindings);
    if (bindings.isEmpty && _binding != null) {
      bindings.add(_binding!);
    }
    _bindings.clear();
    _binding = null;
    for (final binding in bindings) {
      try {
        await _unbind(binding);
      } catch (_) {
        // The command also checks this process start time before signaling, so
        // an orphaned bind cannot signal a later process that reuses its PID.
      }
    }
  }

  Future<void> _unbind(_Binding binding) async {
    final lua = await _detectLua();
    final handle = binding.luaHandle ??
        _hyprlandHandle(binding.marker, binding.modifierMask, binding.key);
    final result = await _runCommand(
        'hyprctl',
        lua
            ? ['eval', _removeHyprlandLuaHandle(handle)]
            : ['keyword', 'unbind', '${binding.modifiers},${binding.key}']);
    _requireOk(result, "Couldn't remove the Hyprland shortcut.");
  }

  Future<void> _removeStaleOwnedBinds(List<_Bind> binds) async {
    for (final bind in binds) {
      final marker =
          RegExp(r'ACBMESH_SIGNAL_(\d+)_(\d+)').firstMatch(bind.argument);
      if (marker == null ||
          _bindings.any((owned) => owned.marker == marker.group(0))) {
        continue;
      }
      final pid = int.tryParse(marker.group(1)!);
      final startTicks = int.tryParse(marker.group(2)!);
      if (pid == null || startTicks == null) continue;
      try {
        if (await _processStartTicks(pid) == startTicks) continue;
      } on DesktopIntegrationException catch (error) {
        if (!error.message.contains('no longer available')) continue;
      }
      final markerText = marker.group(0)!;
      final hasOtherBinding = binds.any((other) =>
          !identical(other, bind) &&
          other.modifierMask == bind.modifierMask &&
          other.key.toUpperCase() == bind.key.toUpperCase() &&
          !other.argument.contains(markerText));
      if (hasOtherBinding) continue;
      final modifiers = _modifiersFromMask(bind.modifierMask);
      if (modifiers.isEmpty || bind.key.isEmpty) continue;
      try {
        final lua = await _detectLua();
        final result = await _runCommand(
            'hyprctl',
            lua
                ? [
                    'eval',
                    _removeHyprlandLuaHandle(_hyprlandHandle(
                        markerText, bind.modifierMask, bind.key))
                  ]
                : ['keyword', 'unbind', '${modifiers.join(' ')},${bind.key}']);
        _requireOk(result, "Couldn't remove an old Arcade shortcut.");
      } catch (_) {
        // Continue cleanup for the remaining app-owned binds.
      }
    }
  }

  Future<List<_Bind>> _readBinds() async {
    final result = await _runCommand('hyprctl', ['-j', 'binds']);
    if (result.exitCode != 0) {
      throw DesktopIntegrationException(
          'Hyprland shortcut support is unavailable: ${_processError(result)}');
    }
    try {
      final value = jsonDecode(result.stdout as String);
      if (value is! List) throw const FormatException('Expected a bind list.');
      return value
          .whereType<Map<String, dynamic>>()
          .map(_Bind.fromJson)
          .toList(growable: false);
    } catch (_) {
      throw const DesktopIntegrationException(
          'Hyprland did not return a readable shortcut list. No shortcut was changed.');
    }
  }

  Future<bool> probe() async {
    try {
      // Reading the bind table verifies that this process can reach the
      // compositor's runtime configuration endpoint. It must not depend on a
      // focused window: login sessions often start on an empty workspace.
      await _readBinds();
      return true;
    } catch (error) {
      Diagnostics.log('shortcut', 'Hyprland probe failed: $error');
      return false;
    }
  }

  Future<HyprlandTarget> captureTarget() async {
    final result = await _runCommand('hyprctl', ['-j', 'activewindow']);
    if (result.exitCode != 0) {
      throw DesktopIntegrationException(
          "Couldn't find the focused app through Hyprland: ${_processError(result)}");
    }
    dynamic value;
    try {
      value = jsonDecode(result.stdout as String);
    } catch (_) {
      throw const DesktopIntegrationException(
          'Hyprland returned unreadable focused-window data. Copy fallback is available.');
    }
    final address = value is Map ? value['address'] : null;
    final pid = value is Map && value['pid'] is num
        ? (value['pid'] as num).toInt()
        : null;
    if (address is! String || !RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(address)) {
      throw const DesktopIntegrationException(
          'Hyprland did not provide a focused window address. Copy fallback is available.');
    }
    if (pid == null || pid <= 0) {
      throw const DesktopIntegrationException(
          'Hyprland did not provide the focused app PID. Copy fallback is available.');
    }
    final startTicks = await _processStartTicks(pid);
    final className = value is Map && value['class'] is String
        ? value['class'] as String
        : '';
    return HyprlandTarget(
        address: address.toLowerCase(),
        pid: pid,
        startTicks: startTicks,
        className: className);
  }

  Future<void> assertTargetExists(HyprlandTarget target,
      {bool requireActive = false}) async {
    final startTicks = await _processStartTicks(target.pid);
    if (startTicks != target.startTicks) {
      throw const DesktopIntegrationException(
          'The previously focused Hyprland app has exited or its PID was reused. Copy the clip and paste manually.');
    }

    final result = await _runCommand('hyprctl', ['-j', 'clients']);
    if (result.exitCode != 0) {
      throw DesktopIntegrationException(
          "Couldn't check the previous window through Hyprland: ${_processError(result)}");
    }
    dynamic clients;
    try {
      clients = jsonDecode(result.stdout as String);
    } catch (_) {
      throw const DesktopIntegrationException(
          'Hyprland returned unreadable window data. Copy fallback is available.');
    }
    final exists = clients is List &&
        clients.any((client) =>
            client is Map &&
            client['address'] is String &&
            (client['address'] as String).toLowerCase() == target.address &&
            client['pid'] is num &&
            (client['pid'] as num).toInt() == target.pid);
    if (!exists) {
      throw const DesktopIntegrationException(
          'The previously focused Hyprland window is no longer available. Copy the clip and paste manually.');
    }
    if (requireActive) {
      final active = await captureTarget();
      if (!active.sameIdentity(target)) {
        throw const DesktopIntegrationException(
            'Hyprland did not restore the previous app focus. Copy the clip and paste manually.');
      }
    }
  }

  Future<void> dispatch(String dispatcher, String argument,
      {String modifiers = 'CTRL'}) async {
    if (!await _detectLua()) {
      final result =
          await _runCommand('hyprctl', ['dispatch', dispatcher, argument]);
      _requireOk(result, "Couldn't paste through Hyprland.");
      return;
    }
    final target = this.target;
    if (target == null ||
        !RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(target.address)) {
      throw const DesktopIntegrationException(
          'The paste target is no longer available.');
    }
    final action = switch (dispatcher) {
      'focuswindow' => 'hl.dsp.focus({ window = w })',
      'sendshortcut' =>
        'hl.dsp.send_shortcut({ mods = ${_luaString(modifiers)}, key = "V", window = w })',
      _ => throw DesktopIntegrationException(
          'Unsupported Hyprland action: $dispatcher'),
    };
    final expression =
        'local w = hl.get_window(${_luaString('address:${target.address}')}); '
        'assert(w and w.pid == ${target.pid}, "The paste target is no longer available"); '
        'local r = hl.dispatch($action); assert(r and r.ok, r and r.error or "Hyprland rejected the paste action")';
    final result = await _runCommand('hyprctl', ['eval', expression]);
    _requireOk(result, "Couldn't paste through Hyprland.");
  }

  Future<bool> _detectLua() async {
    if (_lua != null) return _lua!;
    final status = await _runCommand('hyprctl', ['-j', 'status']);
    if (status.exitCode == 0) {
      try {
        final value = jsonDecode(status.stdout as String);
        if (value is Map && value['configProvider'] is String) {
          return _lua = value['configProvider'] == 'lua';
        }
      } on FormatException catch (_) {
        // Older compositors do not expose the configuration provider.
      }
    }
    if (_lua != null) return _lua!;
    final probe = await _runCommand('hyprctl', [
      'eval',
      'assert(type(hl) == "table" and type(hl.bind) == "function")'
    ]);
    return _lua = probe.exitCode == 0 &&
        (probe.stdout as String).trim().toLowerCase() == 'ok';
  }

  void _requireOk(ProcessResult result, String fallback) {
    if (result.exitCode != 0 ||
        (result.stdout as String).trim().toLowerCase() != 'ok') {
      final reason = _processError(result);
      throw DesktopIntegrationException(
          '$fallback${reason.isEmpty ? '' : ' $reason'}');
    }
  }

  Future<int> _processStartTicks(int pid) async {
    late final String stat;
    try {
      stat = await File('/proc/$pid/stat').readAsString();
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (code == 2 || code == 3) {
        throw const DesktopIntegrationException(
            'The target Hyprland app process is no longer available.');
      }
      throw const DesktopIntegrationException(
          "Couldn't safely check the target app's process.");
    } catch (_) {
      throw const DesktopIntegrationException(
          "Couldn't safely check the target app's process.");
    }
    final closingParenthesis = stat.lastIndexOf(')');
    if (closingParenthesis < 0) {
      throw const DesktopIntegrationException(
          "Couldn't safely register a Hyprland shortcut for this process.");
    }
    final fields =
        stat.substring(closingParenthesis + 1).trim().split(RegExp(r'\s+'));
    // /proc/PID/stat fields 3..22 follow the process name; starttime is field 22.
    if (fields.length <= 19) {
      throw const DesktopIntegrationException(
          "Couldn't safely register a Hyprland shortcut for this process.");
    }
    final ticks = int.tryParse(fields[19]);
    if (ticks == null) {
      throw const DesktopIntegrationException(
          "Couldn't safely register a Hyprland shortcut for this process.");
    }
    return ticks;
  }
}

class _Binding {
  const _Binding({
    required this.modifiers,
    required this.key,
    required this.modifierMask,
    required this.marker,
    this.luaHandle,
  });

  final String modifiers;
  final String key;
  final int modifierMask;
  final String marker;
  final String? luaHandle;
}

class HyprlandTarget {
  const HyprlandTarget(
      {required this.address,
      required this.pid,
      required this.startTicks,
      this.className = ''});

  final String address;
  final int pid;
  final int startTicks;
  final String className;

  /// Terminals reserve Ctrl+V; they paste the clipboard with Ctrl+Shift+V.
  String get pasteModifiers =>
      isTerminalWindowClass(className) ? 'CTRL SHIFT' : 'CTRL';

  bool sameIdentity(HyprlandTarget other) =>
      address == other.address &&
      pid == other.pid &&
      startTicks == other.startTicks;
}

class _Bind {
  const _Bind(
      {required this.modifierMask, required this.key, required this.argument});

  final int modifierMask;
  final String key;
  final String argument;

  factory _Bind.fromJson(Map<String, dynamic> value) => _Bind(
        modifierMask: value['modmask'] is int ? value['modmask'] as int : -1,
        key: value['key'] is String ? value['key'] as String : '',
        argument: '${value['arg'] is String ? value['arg'] : ''} '
            '${value['description'] is String ? value['description'] : ''}',
      );
}

List<String> _modifiersFromMask(int mask) {
  const maskToName = <int, String>{
    4: 'CTRL',
    1: 'SHIFT',
    8: 'ALT',
    64: 'SUPER'
  };
  final names = <String>[];
  for (final entry in maskToName.entries) {
    if ((mask & entry.key) != 0) names.add(entry.value);
  }
  return names;
}

String _processError(ProcessResult result) {
  final stderr = (result.stderr as String).trim();
  if (stderr.isNotEmpty) return stderr;
  return (result.stdout as String).trim();
}

String _hyprlandHandle(String marker, int mask, String key) =>
    '${marker}_${mask}_${key.toUpperCase()}';

String _removeHyprlandLuaHandle(String handle) {
  final key = _luaString(handle);
  return 'local b = rawget(_G, $key); if b then b:remove(); rawset(_G, $key, nil) end';
}

String _luaString(String value) {
  final result = StringBuffer('"');
  for (final rune in value.runes) {
    if (rune == 34 || rune == 92) {
      result.write('\\${String.fromCharCode(rune)}');
    } else if (rune < 32 || rune == 127) {
      result.write('\\${rune.toString().padLeft(3, '0')}');
    } else {
      result.write(String.fromCharCode(rune));
    }
  }
  return '${result.toString()}"';
}
