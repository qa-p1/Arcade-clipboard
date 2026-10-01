import 'dart:convert';
import 'dart:typed_data';

class MeshStatus {
  const MeshStatus({
    required this.initialized,
    required this.meshId,
    required this.deviceId,
    required this.deviceName,
    required this.paused,
    required this.connection,
    required this.diagnostic,
    this.transport = 'offline',
    this.revision = 0,
    this.pendingPairings = const [],
  });

  final bool initialized;
  final String? meshId;
  final String? deviceId;
  final String deviceName;
  final bool paused;
  final String connection;
  final String diagnostic;
  final String transport;
  final int revision;
  final List<PairingRequest> pendingPairings;

  bool get hasMesh => meshId != null && meshId!.isNotEmpty;

  factory MeshStatus.fromJson(Map<String, dynamic> json) => MeshStatus(
        initialized: json['initialized'] == true,
        meshId: _nullableString(json['mesh_id']),
        deviceId: _nullableString(json['device_id']),
        deviceName: json['device_name'] as String? ?? 'This device',
        paused: json['paused'] == true,
        connection: json['connection'] as String? ?? 'offline',
        diagnostic: json['diagnostic'] as String? ?? '',
        transport: json['transport'] as String? ?? 'offline',
        revision: _integer(json['revision']) ?? 0,
        pendingPairings:
            (json['pending_pairings'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map(PairingRequest.fromJson)
                .toList(growable: false),
      );
}

class ClipboardItem {
  const ClipboardItem({
    required this.id,
    required this.originDevice,
    required this.sourceName,
    required this.createdAt,
    this.expiresAt,
    required this.text,
    required this.kind,
    required this.pinned,
    this.representations = const [],
    this.size = 0,
    this.previewText = '',
  });

  final String id;
  final String originDevice;
  final String sourceName;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final String text;
  final String kind;
  final bool pinned;
  final List<ClipRepresentation> representations;
  final int size;
  final String previewText;

  bool get hasBinaryContent =>
      kind == 'image' || kind == 'file' || kind == 'files';
  bool get canInsertText => !hasBinaryContent && text.isNotEmpty;

  bool isExpiredAt(DateTime now) =>
      !pinned && expiresAt != null && !expiresAt!.isAfter(now);

  factory ClipboardItem.fromJson(Map<String, dynamic> json) => ClipboardItem(
        id: json['id'] as String? ?? '',
        originDevice: json['origin_device'] as String? ?? '',
        sourceName: json['source_name'] as String? ?? 'Unknown device',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            _integer(json['created_at']) ?? 0),
        expiresAt: _date(json['expires_at']),
        text: json['text'] as String? ?? '',
        kind: json['kind'] as String? ?? 'text',
        pinned: json['pinned'] == true,
        size: _integer(json['size']) ?? 0,
        previewText: json['preview'] as String? ?? '',
        representations: (json['representations'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ClipRepresentation.fromJson)
            .toList(growable: false),
      );

  String get preview {
    final normalized = (previewText.isNotEmpty ? previewText : text)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty && hasBinaryContent) {
      final names = representations
          .map((value) => value.name)
          .whereType<String>()
          .toList();
      return names.isNotEmpty
          ? names.join(', ')
          : kind == 'image'
              ? 'Image'
              : 'Shared file';
    }
    if (normalized.length <= 180) return normalized;
    return '${normalized.substring(0, 177)}…';
  }

  String get searchText => '$text $sourceName $kind'.toLowerCase();

  Map<String, Object?> toKeyboardJson() => {
        'id': id,
        'source_name': sourceName,
        'created_at': createdAt.millisecondsSinceEpoch,
        if (!pinned && expiresAt != null)
          'expires_at': expiresAt!.millisecondsSinceEpoch,
        'text': text,
        'pinned': pinned,
      };
}

class ClipRepresentation {
  const ClipRepresentation(
      {required this.mimeType, this.name, this.size = 0, this.bytes});

  final String mimeType;
  final String? name;
  final int size;
  final Uint8List? bytes;

  factory ClipRepresentation.fromJson(Map<String, dynamic> json) {
    final encoded = json['data_base64'] as String?;
    final bytes = encoded == null ? null : base64Decode(encoded);
    return ClipRepresentation(
      mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
      name: json['name'] as String?,
      size: _integer(json['size']) ?? bytes?.length ?? 0,
      bytes: bytes,
    );
  }

  Map<String, Object?> toJson() => {
        'mime_type': mimeType,
        if (name != null) 'name': name,
        if (bytes != null) 'data_base64': base64Encode(bytes!),
      };
}

class ClipboardPayload {
  const ClipboardPayload(
      {required this.text, required this.kind, required this.representations});
  final String text;
  final String kind;
  final List<ClipRepresentation> representations;

  factory ClipboardPayload.fromJson(Map<String, dynamic> json) =>
      ClipboardPayload(
        text: json['text'] as String? ?? '',
        kind: json['kind'] as String? ?? 'text',
        representations: (json['representations'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ClipRepresentation.fromJson)
            .toList(growable: false),
      );
}

class MeshDevice {
  const MeshDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.state,
    required this.lastSeen,
    this.isOwner = false,
  });

  final String id;
  final String name;
  final String platform;
  final String state;
  final DateTime? lastSeen;
  final bool isOwner;

  factory MeshDevice.fromJson(Map<String, dynamic> json) => MeshDevice(
        id: json['id'] as String? ?? json['device_id'] as String? ?? '',
        name: json['name'] as String? ??
            json['device_name'] as String? ??
            'Device',
        platform: json['platform'] as String? ?? 'Device',
        state:
            json['state'] as String? ?? json['status'] as String? ?? 'offline',
        lastSeen: _date(json['last_seen']),
        isOwner: json['is_owner'] == true,
      );
}

class PairingRequest {
  const PairingRequest({
    required this.sessionId,
    required this.peerName,
    required this.verificationCode,
    required this.expiresAt,
    required this.direction,
    this.state = 'pending',
  });

  final String sessionId;
  final String peerName;
  final String verificationCode;
  final DateTime? expiresAt;
  final String direction;
  final String state;

  factory PairingRequest.fromJson(Map<String, dynamic> json) => PairingRequest(
        sessionId: json['session_id'] as String? ?? '',
        peerName: json['peer_name'] as String? ?? 'New device',
        verificationCode: json['verification_code'] as String? ?? '',
        expiresAt: _date(json['expires_at']),
        direction: json['direction'] as String? ?? 'inbound',
        state: json['state'] as String? ?? 'pending',
      );

  factory PairingRequest.fromJoinResponse(Map<String, dynamic> json) =>
      PairingRequest.fromJson({
        ...json,
        'direction': json['direction'] ?? 'outbound',
      });
}

class PairingInvite {
  const PairingInvite({required this.invite, required this.expiresAt});

  final String invite;
  final DateTime? expiresAt;

  factory PairingInvite.fromJson(Map<String, dynamic> json) => PairingInvite(
        invite: json['invite'] as String? ?? '',
        expiresAt: _date(json['expires_at']),
      );

  String get displayCode {
    try {
      final decoded = jsonDecode(invite);
      if (decoded is Map<String, dynamic>) {
        return decoded['code'] as String? ?? invite;
      }
    } on FormatException {
      // Older core builds may return a compact opaque invite string.
    }
    return invite;
  }
}

String? _nullableString(Object? value) {
  if (value is String && value.isNotEmpty) return value;
  return null;
}

DateTime? _date(Object? value) {
  if (value is String) {
    final milliseconds = int.tryParse(value);
    if (milliseconds != null) {
      return DateTime.fromMillisecondsSinceEpoch(milliseconds);
    }
    return DateTime.tryParse(value);
  }
  final milliseconds = _integer(value);
  if (milliseconds != null) {
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }
  return null;
}

int? _integer(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
