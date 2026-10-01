import 'package:flutter/services.dart';

/// Small platform channel surface for actions Flutter cannot perform reliably:
/// remembering the focused application and requesting a platform-native paste.
class ArcadeDesktopBridge {
  ArcadeDesktopBridge({MethodChannel? methodChannel})
      : _channel = methodChannel ?? const MethodChannel(_channelName);

  static const _channelName = 'arcade_clipboard/desktop_bridge';

  final MethodChannel _channel;

  /// Runs on the existing engine so hiding the desktop window leaves sync alive.
  void setLifecycleHandler(Future<void> Function(String action)? handler) {
    _channel.setMethodCallHandler(handler == null
        ? null
        : (call) async {
            if (call.method == 'showMainWindow' || call.method == 'quitRequested' || call.method == 'clipboardChanged') {
              await handler(call.method);
            }
          });
  }

  /// Returns compatible representations without converting images into text.
  /// Each format contains `mimeType` and a Uint8List `bytes` value. `files`
  /// contains local file paths; callers import their bytes into the mesh.
  Future<Map<String, Object?>> readClipboard() async =>
      await _channel.invokeMapMethod<String, Object?>('readClipboard') ?? const {};

  Future<void> writeClipboard({
    required List<Map<String, Object?>> formats,
    List<String> files = const [],
  }) => _channel.invokeMethod<void>('writeClipboard', {
        'formats': formats,
        'files': files,
      });

  Future<void> setBackgroundEnabled(bool enabled) =>
      _channel.invokeMethod<void>('setBackgroundEnabled', {'enabled': enabled});

  Future<void> setLaunchAtLogin(bool enabled) =>
      _channel.invokeMethod<void>('setLaunchAtLogin', {'enabled': enabled});

  Future<bool> launchAtLoginEnabled() async =>
      await _channel.invokeMethod<bool>('launchAtLoginEnabled') ?? false;

  Future<int> clipboardRevision() async =>
      await _channel.invokeMethod<int>('clipboardRevision') ?? 0;

  Future<void> setClipboardCaptureEnabled(bool enabled) =>
      _channel.invokeMethod<void>('setClipboardCaptureEnabled', {'enabled': enabled});

  Future<Map<String, Object?>> capabilities() async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'capabilities',
    );
    return value ?? const {};
  }

  Future<bool> requestPasteAccess() async =>
      await _channel.invokeMethod<bool>('requestPasteAccess') ?? false;

  Future<void> rememberTarget() => _channel.invokeMethod<void>('rememberTarget');

  Future<void> restoreTargetFocus() =>
      _channel.invokeMethod<void>('restoreTargetFocus');

  /// Sends the platform's standard paste keystroke to the remembered target.
  /// The caller is responsible for setting the system clipboard first.
  Future<void> pasteKey() => _channel.invokeMethod<void>('pasteKey');
}
