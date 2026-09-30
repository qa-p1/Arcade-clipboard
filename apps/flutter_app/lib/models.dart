import 'dart:convert';

class MeshStatus {
  const MeshStatus({
    required this.initialized,
    required this.meshId,
    required this.deviceId,
    required this.deviceName,
    required this.paused,
    required this.connection,
    required this.diagnostic,
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
        revision: _integer(json['revision']) ?? 0,
        pendingPairings: (json['pending_pairings'] as List<dynamic>? ?? const [])
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
  });

  final String id;
  final String originDevice;
  final String sourceName;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final String text;
  final String kind;
  final bool pinned;

  bool isExpiredAt(DateTime now) => expiresAt != null && !expiresAt!.isAfter(now);

  factory ClipboardItem.fromJson(Map<String, dynamic> json) => ClipboardItem(
        id: json['id'] as String? ?? '',
        originDevice: json['origin_device'] as String? ?? '',
        sourceName: json['source_name'] as String? ?? 'Unknown device',
        createdAt: DateTime.fromMillisecondsSinceEpoch(_integer(json['created_at']) ?? 0),
        expiresAt: _date(json['expires_at']),
        text: json['text'] as String? ?? '',
        kind: json['kind'] as String? ?? 'text',
        pinned: json['pinned'] == true,
      );

  String get preview {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 180) return normalized;
    return '${normalized.substring(0, 177)}…';
  }

  String get searchText => '$text $sourceName $kind'.toLowerCase();

  Map<String, Object?> toKeyboardJson() => {
        'id': id,
        'source_name': sourceName,
        'created_at': createdAt.millisecondsSinceEpoch,
        if (expiresAt != null) 'expires_at': expiresAt!.millisecondsSinceEpoch,
        'text': text,
        'pinned': pinned,
      };
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
        name: json['name'] as String? ?? json['device_name'] as String? ?? 'Device',
        platform: json['platform'] as String? ?? 'Device',
        state: json['state'] as String? ?? json['status'] as String? ?? 'offline',
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

  factory PairingRequest.fromJoinResponse(Map<String, dynamic> json) => PairingRequest.fromJson({
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
    if (milliseconds != null) return DateTime.fromMillisecondsSinceEpoch(milliseconds);
    return DateTime.tryParse(value);
  }
  final milliseconds = _integer(value);
  if (milliseconds != null) return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return null;
}

int? _integer(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
