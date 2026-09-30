import 'package:flutter/services.dart';

/// Small platform channel surface for actions Flutter cannot perform reliably:
/// remembering the focused application and requesting a platform-native paste.
class ArcadeDesktopBridge {
  ArcadeDesktopBridge({MethodChannel? methodChannel})
      : _channel = methodChannel ?? const MethodChannel(_channelName);

  static const _channelName = 'arcade_clipboard/desktop_bridge';

  final MethodChannel _channel;

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
