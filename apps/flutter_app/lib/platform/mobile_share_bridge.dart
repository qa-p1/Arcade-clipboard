import 'package:flutter/services.dart';
import '../models.dart';

class SharedClip {
  const SharedClip(
      {required this.id,
      required this.text,
      this.kind = 'text',
      this.representations = const []});

  final String id;
  final String text;
  final String kind;
  final List<ClipRepresentation> representations;

  factory SharedClip.fromMap(Map<Object?, Object?> map) => SharedClip(
        id: map['id'] as String? ?? '',
        text: map['text'] as String? ?? '',
        kind: map['kind'] as String? ?? 'text',
        representations: (map['representations'] as List<dynamic>? ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((value) => ClipRepresentation.fromJson(
                value.map((key, value) => MapEntry(key.toString(), value))))
            .toList(growable: false),
      );
}

class MobileShareBridge {
  static const MethodChannel _channel =
      MethodChannel('arcade_clipboard/mobile');

  void setDiscoveryHandler(
      Future<void> Function(Map<String, dynamic>)? handler) {
    _channel.setMethodCallHandler(handler == null ? null : (call) async {
      if (call.method == 'peerDiscovered' && call.arguments is Map) {
        await handler(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
  }

  Future<void> configureDiscovery(Map<String, dynamic> configuration) =>
      _channel.invokeMethod<void>('configureDiscovery', configuration);
  Future<void> stopDiscovery() =>
      _channel.invokeMethod<void>('stopDiscovery');
  Future<void> primeLocalNetwork() =>
      _channel.invokeMethod<void>('primeLocalNetwork');

  Future<void> writeClipboard({required List<Map<String, Object?>> formats}) =>
      _channel.invokeMethod<void>('writeClipboard', {'formats': formats});

  Future<void> openKeyboardSettings() =>
      _channel.invokeMethod<void>('openKeyboardSettings');
  Future<void> exportFile({required String name, required Uint8List bytes}) =>
      _channel.invokeMethod<void>('exportFile', {'name': name, 'bytes': bytes});

  Future<List<SharedClip>> drainSharedInbox() async {
    final raw = await _channel.invokeMethod<List<Object?>>('drainSharedInbox');
    return (raw ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(SharedClip.fromMap)
        .where((clip) =>
            clip.id.isNotEmpty &&
            (clip.text.isNotEmpty || clip.representations.isNotEmpty))
        .toList(growable: false);
  }

  Future<void> acknowledgeSharedInbox(Iterable<String> ids) async {
    final values = ids.where((id) => id.isNotEmpty).toList(growable: false);
    if (values.isEmpty) return;
    await _channel.invokeMethod<void>('ackSharedInbox', {'ids': values});
  }

  Future<void> publishKeyboardHistory({
    required List<Map<String, Object?>> items,
    required bool paused,
  }) async {
    await _channel.invokeMethod<void>('publishKeyboardHistory', {
      'items': items,
      'paused': paused,
    });
  }
}
