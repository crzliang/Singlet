import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'dns_defaults.dart';
import 'rule_set_store.dart';

/// Writes bundled / generated sing-box JSON into a stable on-disk path.
class ConfigStore {
  static const draftFileName = 'from-clash-draft.json';
  static const metaSidecarName = 'from-clash-draft.meta.json';

  /// Top-level keys accepted by sing-box option.Options (unknown → reject).
  static const allowedTopLevelKeys = {
    r'$schema',
    'log',
    'dns',
    'ntp',
    'certificate',
    'endpoints',
    'inbounds',
    'outbounds',
    'route',
    'services',
    'experimental',
  };

  Future<Directory> _configsDir() async {
    final dir = await getApplicationSupportDirectory();
    final configs = Directory('${dir.path}/configs');
    if (!await configs.exists()) {
      await configs.create(recursive: true);
    }
    return configs;
  }

  Future<String> configsDirPath() async => (await _configsDir()).path;

  Future<void> deleteConfig(String name) async {
    final configs = await _configsDir();
    final file = File('${configs.path}/$name');
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<String> ensureMinimalDirectConfig() async {
    final configs = await _configsDir();
    final file = File('${configs.path}/minimal-direct.json');
    final bundled = await rootBundle.loadString(
      'assets/configs/minimal-direct.json',
    );
    await file.writeAsString(bundled);
    return file.path;
  }

  /// Prefer Clash import draft when present; otherwise minimal-direct.
  /// Strips legacy `_singlet_meta` (and other unknown top-level keys) before return.
  Future<String> resolveDefaultConfigPath() async {
    final configs = await _configsDir();
    final draft = File('${configs.path}/$draftFileName');
    if (await draft.exists()) {
      await sanitizeConfigFile(draft);
      return draft.path;
    }
    return ensureMinimalDirectConfig();
  }

  Future<String> writeGeneratedConfig(
    String json, {
    String name = 'active.json',
    Map<String, dynamic>? meta,
  }) async {
    final configs = await _configsDir();
    final cleaned = sanitizeConfigJsonString(json);
    final file = File('${configs.path}/$name');
    await file.writeAsString(cleaned);
    if (meta != null) {
      final sidecarName = name.endsWith('.json')
          ? '${name.substring(0, name.length - 5)}.meta.json'
          : '$name.meta.json';
      final sidecar = File('${configs.path}/$sidecarName');
      await sidecar.writeAsString(
        const JsonEncoder.withIndent('  ').convert(meta),
      );
    }
    return file.path;
  }

  /// Remove unknown top-level fields; rewrite file if changed.
  Future<bool> sanitizeConfigFile(File file) async {
    if (!await file.exists()) return false;
    final raw = await file.readAsString();
    final cleaned = sanitizeConfigJsonString(raw);
    if (cleaned == raw) return false;
    await file.writeAsString(cleaned);
    return true;
  }

  /// Re-apply current DNS settings onto an existing config file (draft / active).
  Future<void> reapplyDns({
    String? path,
    DnsSettings? dns,
  }) async {
    await reapplyUserSettings(path: path, dns: dns);
  }

  /// Re-apply DNS + listen ports + default route rules onto a config file.
  Future<void> reapplyUserSettings({
    String? path,
    DnsSettings? dns,
    PortSettings? ports,
    BypassRouteSettings? route,
  }) async {
    final targetPath = path ?? await resolveDefaultConfigPath();
    final file = File(targetPath);
    if (!await file.exists()) return;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return;
    final map = Map<String, dynamic>.from(decoded);
    final routeMap = map['route'];
    final finalTag = routeMap is Map
        ? '${routeMap['final'] ?? 'direct'}'
        : 'direct';
    final settings = await AppSettingsStore().load();
    final dnsSettings = dns ?? settings.dns;
    final portSettings = ports ?? settings.ports;
    final routeSettings = route ?? settings.route;
    DnsDefaults.applyToConfig(map, proxyDetour: finalTag, dns: dnsSettings);
    PortSettings.applyProxyInbounds(map, portSettings);
    await applyRouteDefaultsWithLocals(
      map,
      proxyOutbound: finalTag,
      route: routeSettings,
    );
    final cleaned = sanitizeConfigJsonString(
      const JsonEncoder.withIndent('  ').convert(map),
    );
    await file.writeAsString(cleaned);
  }

  /// Drop `_singlet_meta` and any non-sing-box top-level key from a JSON object string.
  String sanitizeConfigJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return raw;
    final map = Map<String, dynamic>.from(decoded);
    final removed = <String>[];
    map.removeWhere((key, _) {
      // Keep only sing-box top-level keys; always drop "_…" app metadata.
      final drop = key.startsWith('_') || !allowedTopLevelKeys.contains(key);
      if (drop) removed.add(key);
      return drop;
    });
    if (removed.isEmpty) return raw;
    return const JsonEncoder.withIndent('  ').convert(map);
  }
}
