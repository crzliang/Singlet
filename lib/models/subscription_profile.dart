/// Remote Clash subscription vs local import (share link / sing-box JSON).
enum ProfileKind {
  remote,
  local,
}

extension ProfileKindX on ProfileKind {
  String get wireValue => switch (this) {
        ProfileKind.remote => 'remote',
        ProfileKind.local => 'local',
      };

  String get label => switch (this) {
        ProfileKind.remote => '远程订阅',
        ProfileKind.local => '本地订阅',
      };

  static ProfileKind fromWire(String? raw, {String url = ''}) {
    switch (raw) {
      case 'local':
        return ProfileKind.local;
      case 'remote':
        return ProfileKind.remote;
      default:
        // Legacy profiles: no URL → treat as local.
        return url.trim().isEmpty ? ProfileKind.local : ProfileKind.remote;
    }
  }
}

/// One Clash subscription / profile card (Clash Verge「配置」).
class SubscriptionProfile {
  SubscriptionProfile({
    required this.id,
    required this.name,
    required this.url,
    this.kind = ProfileKind.remote,
    this.autoUpdate = true,
    this.autoUpdateIntervalMin = 1440,
    this.updatedAt,
    this.expireAt,
    this.upload,
    this.download,
    this.total,
    this.configFileName,
    this.mappedCount,
    this.proxyTotal,
  });

  final String id;
  String name;
  String url;
  ProfileKind kind;
  bool autoUpdate;
  int autoUpdateIntervalMin;
  DateTime? updatedAt;
  DateTime? expireAt;
  int? upload;
  int? download;
  int? total;
  String? configFileName;
  int? mappedCount;
  int? proxyTotal;

  bool get isLocal => kind == ProfileKind.local;
  bool get isRemote => kind == ProfileKind.remote;

  String get resolvedConfigFileName =>
      configFileName ?? 'profile_$id.json';

  int? get usedBytes {
    if (upload == null && download == null) return null;
    return (upload ?? 0) + (download ?? 0);
  }

  factory SubscriptionProfile.fromJson(Map<String, dynamic> json) {
    DateTime? parseTs(dynamic v) {
      if (v == null) return null;
      if (v is int) {
        // seconds vs millis
        final ms = v > 1000000000000 ? v : v * 1000;
        return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
      }
      return DateTime.tryParse('$v')?.toLocal();
    }

    final url = '${json['url'] ?? ''}';
    return SubscriptionProfile(
      id: '${json['id']}',
      name: '${json['name'] ?? '未命名'}',
      url: url,
      kind: ProfileKindX.fromWire(json['kind']?.toString(), url: url),
      autoUpdate: json['autoUpdate'] as bool? ?? true,
      autoUpdateIntervalMin: (json['autoUpdateIntervalMin'] as num?)?.toInt() ??
          1440,
      updatedAt: parseTs(json['updatedAt']),
      expireAt: parseTs(json['expireAt']),
      upload: (json['upload'] as num?)?.toInt(),
      download: (json['download'] as num?)?.toInt(),
      total: (json['total'] as num?)?.toInt(),
      configFileName: json['configFileName'] as String?,
      mappedCount: (json['mappedCount'] as num?)?.toInt(),
      proxyTotal: (json['proxyTotal'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'kind': kind.wireValue,
        'autoUpdate': autoUpdate,
        'autoUpdateIntervalMin': autoUpdateIntervalMin,
        'updatedAt': updatedAt?.toUtc().toIso8601String(),
        'expireAt': expireAt?.toUtc().toIso8601String(),
        'upload': upload,
        'download': download,
        'total': total,
        'configFileName': resolvedConfigFileName,
        'mappedCount': mappedCount,
        'proxyTotal': proxyTotal,
      };

  SubscriptionProfile copyWith({
    String? name,
    String? url,
    ProfileKind? kind,
    bool? autoUpdate,
    int? autoUpdateIntervalMin,
    DateTime? updatedAt,
    DateTime? expireAt,
    int? upload,
    int? download,
    int? total,
    String? configFileName,
    int? mappedCount,
    int? proxyTotal,
  }) {
    return SubscriptionProfile(
      id: id,
      name: name ?? this.name,
      url: url ?? this.url,
      kind: kind ?? this.kind,
      autoUpdate: autoUpdate ?? this.autoUpdate,
      autoUpdateIntervalMin:
          autoUpdateIntervalMin ?? this.autoUpdateIntervalMin,
      updatedAt: updatedAt ?? this.updatedAt,
      expireAt: expireAt ?? this.expireAt,
      upload: upload ?? this.upload,
      download: download ?? this.download,
      total: total ?? this.total,
      configFileName: configFileName ?? this.configFileName,
      mappedCount: mappedCount ?? this.mappedCount,
      proxyTotal: proxyTotal ?? this.proxyTotal,
    );
  }
}

/// Parsed `subscription-userinfo` response header.
class SubscriptionUserInfo {
  const SubscriptionUserInfo({
    this.upload,
    this.download,
    this.total,
    this.expire,
  });

  final int? upload;
  final int? download;
  final int? total;

  /// Unix epoch seconds.
  final int? expire;

  DateTime? get expireAt {
    final e = expire;
    if (e == null || e <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(e * 1000, isUtc: true).toLocal();
  }
}
