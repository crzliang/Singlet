import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../models/subscription_profile.dart';
import 'config_store.dart';

/// Persists multi-profile list under Application Support.
class ProfileStore {
  ProfileStore({ConfigStore? configStore})
      : _configStore = configStore ?? ConfigStore();

  final ConfigStore _configStore;

  static const indexFileName = 'profiles.json';

  List<SubscriptionProfile> _profiles = [];
  String? _activeId;

  List<SubscriptionProfile> get profiles => List.unmodifiable(_profiles);
  String? get activeId => _activeId;

  SubscriptionProfile? get activeProfile {
    final id = _activeId;
    if (id == null) return null;
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<Directory> _appSupport() async => getApplicationSupportDirectory();

  Future<File> _indexFile() async {
    final dir = await _appSupport();
    final profilesDir = Directory('${dir.path}/profiles');
    if (!await profilesDir.exists()) {
      await profilesDir.create(recursive: true);
    }
    return File('${profilesDir.path}/$indexFileName');
  }

  Future<void> load() async {
    final file = await _indexFile();
    if (!await file.exists()) {
      _profiles = [];
      _activeId = null;
      await _maybeMigrateLegacyDraft();
      return;
    }
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) {
        _profiles = [];
        _activeId = null;
        return;
      }
      _activeId = raw['activeId'] as String?;
      final list = raw['profiles'];
      if (list is List) {
        _profiles = list
            .whereType<Map>()
            .map((e) => SubscriptionProfile.fromJson(
                  Map<String, dynamic>.from(e),
                ))
            .toList();
      } else {
        _profiles = [];
      }
    } catch (_) {
      _profiles = [];
      _activeId = null;
    }
  }

  /// If old single draft exists and no profiles yet, surface a local-only card.
  Future<void> _maybeMigrateLegacyDraft() async {
    final path = await _configStore.configsDirPath();
    final draft = File('$path/${ConfigStore.draftFileName}');
    if (!await draft.exists()) return;
    final id = _newId();
    final profile = SubscriptionProfile(
      id: id,
      name: '已导入草稿',
      url: '',
      kind: ProfileKind.local,
      autoUpdate: false,
      updatedAt: (await draft.stat()).modified,
      configFileName: ConfigStore.draftFileName,
    );
    _profiles = [profile];
    _activeId = id;
    await persist();
  }

  Future<void> persist() async {
    final file = await _indexFile();
    final payload = {
      'activeId': _activeId,
      'profiles': _profiles.map((e) => e.toJson()).toList(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  String _newId() {
    final r = Random.secure();
    final bytes = List<int>.generate(8, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<SubscriptionProfile> add({
    required String name,
    required String url,
    ProfileKind? kind,
    bool autoUpdate = true,
    int intervalMin = 1440,
    int? mappedCount,
    int? proxyTotal,
    DateTime? updatedAt,
  }) async {
    final id = _newId();
    final trimmedUrl = url.trim();
    final trimmedName = name.trim();
    final resolvedKind = kind ??
        (trimmedUrl.isEmpty ? ProfileKind.local : ProfileKind.remote);
    final profile = SubscriptionProfile(
      id: id,
      name: trimmedName.isEmpty
          ? (resolvedKind == ProfileKind.local
              ? '本地订阅'
              : _nameFromUrl(trimmedUrl))
          : trimmedName,
      url: trimmedUrl,
      kind: resolvedKind,
      autoUpdate: resolvedKind == ProfileKind.local ? false : autoUpdate,
      autoUpdateIntervalMin: intervalMin,
      configFileName: 'profile_$id.json',
      mappedCount: mappedCount,
      proxyTotal: proxyTotal,
      updatedAt: updatedAt,
    );
    _profiles = [..._profiles, profile];
    await persist();
    return profile;
  }

  Future<void> update(SubscriptionProfile profile) async {
    _profiles = [
      for (final p in _profiles)
        if (p.id == profile.id) profile else p,
    ];
    await persist();
  }

  Future<void> remove(String id) async {
    SubscriptionProfile? removed;
    for (final p in _profiles) {
      if (p.id == id) {
        removed = p;
        break;
      }
    }
    _profiles = _profiles.where((p) => p.id != id).toList();
    if (_activeId == id) {
      _activeId = _profiles.isEmpty ? null : _profiles.first.id;
    }
    await persist();
    if (removed != null) {
      final name = removed.resolvedConfigFileName;
      final stillUsed = _profiles.any((p) => p.resolvedConfigFileName == name);
      if (!stillUsed && name != ConfigStore.draftFileName) {
        await _configStore.deleteConfig(name);
      }
    }
  }

  Future<void> setActive(String id) async {
    if (!_profiles.any((p) => p.id == id)) return;
    _activeId = id;
    await persist();
  }

  Future<String?> activeConfigPath() async {
    final p = activeProfile;
    if (p == null) {
      return _configStore.resolveDefaultConfigPath();
    }
    final dir = await _configStore.configsDirPath();
    final file = File('$dir/${p.resolvedConfigFileName}');
    if (await file.exists()) {
      await _configStore.sanitizeConfigFile(file);
      return file.path;
    }
    return _configStore.resolveDefaultConfigPath();
  }

  static String _nameFromUrl(String url) {
    try {
      final u = Uri.parse(url);
      final host = u.host;
      if (host.isNotEmpty) {
        final leaf = u.pathSegments.isNotEmpty ? u.pathSegments.last : '';
        if (leaf.isNotEmpty && leaf.contains('.')) {
          return leaf.length > 24 ? leaf.substring(0, 24) : leaf;
        }
        return host;
      }
    } catch (_) {}
    return '订阅';
  }
}
