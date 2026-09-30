import 'package:flutter/services.dart';

class SharedClip {
  const SharedClip({required this.id, required this.text, this.kind = 'text'});

  final String id;
  final String text;
  final String kind;

  factory SharedClip.fromMap(Map<Object?, Object?> map) => SharedClip(
        id: map['id'] as String? ?? '',
        text: map['text'] as String? ?? '',
        kind: map['kind'] as String? ?? 'text',
      );
}

class MobileShareBridge {
  static const MethodChannel _channel = MethodChannel('arcade_clipboard/mobile');

  Future<List<SharedClip>> drainSharedInbox() async {
    final raw = await _channel.invokeMethod<List<Object?>>('drainSharedInbox');
    return (raw ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(SharedClip.fromMap)
        .where((clip) => clip.id.isNotEmpty && clip.text.isNotEmpty)
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
