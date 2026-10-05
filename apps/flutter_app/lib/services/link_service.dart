import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'core_api.dart';
import 'diagnostics.dart';

/// Arcade Link: working with the other Arcade apps (desktop only).
///
/// The Rust core owns the Link (manifest, endpoint, requests). This service
/// only keeps the user's settings and waits for requests meant for the UI;
/// Dart has no IPC code of its own.
class LinkService {
  LinkService(this._core);

  final CoreApi _core;
  bool _enabled = true;
  List<String> _disabledPeers = const [];
  bool _listening = false;
  bool _closed = false;

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

  /// Whether entries from `peer` (`arcade.box`, …) may appear here.
  bool uses(String peer) => _enabled && !_disabledPeers.contains(peer);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('link_enabled') ?? true;
    _disabledPeers = prefs.getStringList('link_disabled_peers') ?? const [];
  }

  /// The settings as the core expects them in `initialize`/`link_configure`.
  Map<String, Object?> settings(String shortcut) => {
        'enabled': _enabled,
        'disabled_peers': _disabledPeers,
        'shortcut': shortcut,
      };

  /// Starts waiting for UI requests (an idle wait costs nothing).
  void listen() {
    if (_listening || !supported) return;
    _listening = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (!_closed) {
      final Map<String, dynamic> event;
      try {
        event = await _core.invoke('link_wait');
      } catch (exception) {
        Diagnostics.log('link', 'stopped waiting: $exception');
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
          return;
      }
    }
  }

  Future<void> configure(String shortcut) async {
    if (!supported) return;
    await _core.invoke('link_configure', {'link': settings(shortcut)});
  }

  /// Answers a `clipboard.pick` request with the chosen item, an error
  /// when the picker can't open, or neither when the user closed it.
  Future<void> answerPick(int request, {String? itemId, String? error}) =>
      _core.invoke('link_pick_result', {
        'request': request,
        if (itemId != null) 'item_id': itemId,
        if (error != null) 'error': error,
      });

  void close() => _closed = true;
}
