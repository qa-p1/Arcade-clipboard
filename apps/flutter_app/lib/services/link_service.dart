import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'core_api.dart';
import 'diagnostics.dart';

class LinkItemAction {
  LinkItemAction(this.data, {this.disabledReason});
  final Map<String, dynamic> data;
  final String? disabledReason;
  String get peer => data['peer'] as String;
  String get action => data['action'] as String;
  String get title => data['title'] as String;
  String get shortcut => data['shortcut'] as String;
  bool get importsResult => data['import'] == true;
  bool get enabled => disabledReason == null;
}

/// Arcade Link: working with the other Arcade apps (desktop only).
///
/// The Rust core owns the Link (manifest, endpoint, requests). This service
/// only keeps the user's settings and waits for requests meant for the UI;
/// Dart has no IPC code of its own.
class LinkService {
  LinkService(this._core, {this.startedInBackground = false});
  final bool startedInBackground;

  final CoreApi _core;
  bool _enabled = true;
  List<String> _disabledPeers = const [];
  bool _listening = false;
  bool _closed = false;
  Map<String, List<Map<String, dynamic>>> _offers = const {};
  List<Map<String, dynamic>> _peers = const [];
  List<Map<String, dynamic>> _shortcuts = const [];
  Map<String, dynamic> _diagnostics = const {};
  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _busy = false;
  bool _cancelRequested = false;
  int? _request;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Map<int, Map<String, dynamic>> _earlyDone = {};
  String? _progressMessage;
  double? _progressFraction;
  void Function()? onChanged;

  /// Requests from other Arcade apps that need the UI.
  Future<void> Function()? onQuit;
  Future<void> Function()? onShow;

  /// `clipboard.pick`: open the picker for `caller`; the choice goes back
  /// through [answerPick].
  Future<void> Function(int request, String caller)? onPick;

  /// The caller gave up on a pick (the picker should close).
  Future<void> Function(int request)? onPickCancelled;

  static bool get supported =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  bool get enabled => _enabled;
  List<String> get disabledPeers => _disabledPeers;
  List<Map<String, dynamic>> get peers => _peers;
  List<Map<String, dynamic>> get shortcuts => _shortcuts;
  Map<String, dynamic> get diagnostics => _diagnostics;
  bool get busy => _busy;
  String? get progressMessage => _progressMessage;
  double? get progressFraction => _progressFraction;

  /// Pure cached reads: opening an item menu performs no I/O.
  List<LinkItemAction> actionsFor(ClipboardItem item, {bool private = false}) {
    if (!supported || !_enabled) return const [];
    return (_offers[item.kind] ?? const [])
        .where((offer) =>
            offer['available'] == true && uses(offer['peer'] as String))
        .map((offer) {
      final max = offer['max_bytes'] as num?;
      final reason = private
          ? 'Arcade Clipboard is in Private mode.'
          : _busy
              ? 'Arcade Clipboard is busy. Try again when its current job finishes.'
              : offer['reason'] as String? ??
                  (max != null && item.size > max
                      ? offer['limit_reason'] as String?
                      : null);
      return LinkItemAction(offer, disabledReason: reason);
    }).toList(growable: false);
  }

  /// Whether entries from `peer` (`arcade.box`, …) may appear here.
  bool uses(String peer) => _enabled && !_disabledPeers.contains(peer);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('link_enabled') ?? true;
    _disabledPeers = prefs.getStringList('link_disabled_peers') ?? const [];
  }

  /// The settings as the core expects them in `initialize`/`link_configure`.
  Map<String, Object?> settings(String shortcut) => {
        'mode': startedInBackground ? 'background' : 'foreground',
        'enabled': _enabled,
        'disabled_peers': _disabledPeers,
        'shortcut': shortcut,
      };

  /// Starts waiting for UI requests (an idle wait costs nothing).
  void listen() {
    if (_listening || !supported) return;
    _listening = true;
    unawaited(_loop());
    unawaited(refresh());
  }

  Future<void> _loop() async {
    while (!_closed) {
      final Map<String, dynamic> event;
      try {
        event = await _core.invoke('link_wait');
      } catch (exception) {
        Diagnostics.log('link', 'stopped waiting: $exception');
        close();
        return;
      }
      Diagnostics.log('link', 'request ${event['kind']}');
      switch (event['kind']) {
        case 'quit':
          await onQuit?.call();
        case 'show':
          await onShow?.call();
        case 'pick':
          await onPick?.call(event['request'] as int,
              event['caller_name'] as String? ?? 'another app');
        case 'pick_cancelled':
          await onPickCancelled?.call(event['request'] as int);
        case 'closed':
          close();
          return;
        case 'registry_changed':
          // Do not hold up inbound UI requests while probing settings rows.
          unawaited(refresh());
        case 'invoke_progress':
          if (_busy && (_request == null || event['request'] == _request)) {
            _progressMessage = event['message'] as String?;
            _progressFraction = (event['fraction'] as num?)?.toDouble();
            onChanged?.call();
          }
        case 'invoke_done':
          final id = event['request'] as int;
          final pending = _pending.remove(id);
          if (pending != null) {
            pending.complete(event);
          } else {
            _earlyDone[id] = event;
          }
      }
    }
  }

  Future<void> configure(String shortcut) async {
    if (!supported) return;
    await _core.invoke('link_configure', {'link': settings(shortcut)});
    await refresh();
  }

  Future<void> setEnabled(bool value, String shortcut) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('link_enabled', value);
    _enabled = value;
    onChanged?.call();
    await configure(shortcut);
  }

  Future<void> setPeerEnabled(String peer, bool value, String shortcut) async {
    _disabledPeers = [
      ..._disabledPeers.where((id) => id != peer),
      if (!value) peer
    ];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('link_disabled_peers', _disabledPeers);
    onChanged?.call();
    await configure(shortcut);
  }

  Future<void> refresh() async {
    if (_closed || !supported) return;
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        final data = await _core.invoke('link_offers');
        final peers = await _core.invoke('link_peers');
        final diagnostics = await _core.invoke('link_diagnostics');
        if (_closed) return;
        _offers = (data['offers'] as Map<String, dynamic>? ?? const {}).map(
            (kind, values) => MapEntry(kind,
                (values as List).whereType<Map<String, dynamic>>().toList()));
        _peers = (peers['peers'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _shortcuts = (peers['shortcuts'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _diagnostics = {
          ...diagnostics,
          'watching': peers['watching'],
          'tools_installed': peers['tools_installed']
        };
        onChanged?.call();
      } while (_refreshAgain && !_closed);
    } catch (error) {
      Diagnostics.log('link', 'discovery: $error');
    } finally {
      _refreshing = false;
    }
  }

  Future<Map<String, dynamic>> invoke(LinkItemAction action,
      {String? itemId,
      int? stage,
      Map<String, Object?>? input,
      Map<String, Object?>? options}) async {
    if (_busy) throw StateError('An item action is already running.');
    _busy = true;
    _cancelRequested = false;
    _progressMessage = action.title;
    _progressFraction = null;
    onChanged?.call();
    try {
      final reply = await _core.invoke('link_invoke', {
        'peer': action.peer,
        'action': action.action,
        if (itemId != null) 'item_id': itemId,
        if (stage != null) 'stage': stage,
        if (input != null) 'input': input,
        if (options != null) 'options': options,
      });
      final id = reply['request'] as int;
      _request = id;
      if (_cancelRequested) await cancel();
      final early = _earlyDone.remove(id);
      if (early != null) return early;
      final result = Completer<Map<String, dynamic>>();
      _pending[id] = result;
      return await result.future;
    } finally {
      _request = null;
      _busy = false;
      _progressMessage = null;
      _progressFraction = null;
      onChanged?.call();
    }
  }

  String? shortcutOwner(String shortcut) {
    String normalized(String value) {
      final parts = value
          .toLowerCase()
          .split('+')
          .map((p) {
            return switch (p.trim()) {
              'control' || 'ctl' => 'ctrl',
              'option' || 'opt' => 'alt',
              'command' ||
              'cmd' ||
              'super' ||
              'meta' ||
              'win' ||
              'logo' =>
                'super',
              _ => p.trim(),
            };
          })
          .where((p) => p.isNotEmpty)
          .toList();
      if (parts.isEmpty) return '';
      final key = parts.removeLast();
      parts.sort();
      return [...parts, key].join('+');
    }

    final wanted = normalized(shortcut);
    for (final used in _shortcuts) {
      if (wanted.isNotEmpty &&
          normalized(used['accelerator'] as String) == wanted) {
        return used['name'] as String;
      }
    }
    return null;
  }

  Future<void> getApp(String app) async {
    if (_diagnostics['tools_installed'] == true) {
      final event = await invoke(
          LinkItemAction({
            'peer': 'arcade.tools',
            'action': 'tools.install',
            'title': 'Get',
            'shortcut': '',
          }),
          options: {'app': app});
      if (event['error'] != null) throw StateError(event['message'] as String);
    } else {
      await _core.invoke('link_open_releases', {'app': app});
    }
  }

  Future<void> cancel() async {
    _cancelRequested = true;
    if (_request != null) {
      await _core.invoke('link_cancel', {'request': _request});
    }
  }

  Future<int> stageImage(Uint8List bytes, String mime) async {
    final reply = await _core.invoke('link_stage_image', {'mime': mime});
    final stage = reply['stage'] as int;
    try {
      const chunkSize = 512 * 1024;
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        final chunk = Uint8List.sublistView(
            bytes, offset, (offset + chunkSize).clamp(0, bytes.length));
        final encoded = await Isolate.run(() => base64Encode(chunk));
        await _core.invoke(
            'link_stage_image', {'stage': stage, 'data_base64': encoded});
      }
      return stage;
    } catch (_) {
      await discardStage(stage);
      rethrow;
    }
  }

  Future<void> discardStage(int stage) =>
      _core.invoke('link_stage_image', {'stage': stage, 'discard': true});

  /// Answers a `clipboard.pick` request with the chosen item, an error
  /// when the picker can't open, or neither when the user closed it.
  Future<void> answerPick(int request, {String? itemId, String? error}) =>
      _core.invoke('link_pick_result', {
        'request': request,
        if (itemId != null) 'item_id': itemId,
        if (error != null) 'error': error,
      });

  void close() {
    _closed = true;
    for (final pending in _pending.values) {
      pending.complete({
        'message': 'Cancelled.',
        'error': {'code': 'cancelled'}
      });
    }
    _pending.clear();
  }
}
