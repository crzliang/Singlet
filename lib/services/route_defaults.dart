import 'app_settings.dart';
import 'dns_defaults.dart';

/// Built-in China-friendly route rules via remote sing-box rule-sets.
///
/// Injects (when enabled):
/// 1. private / LAN → direct (`ip_is_private`, or local geoip-private.srs)
/// 2. geosite-cn / geoip-cn → direct (optional)
/// 3. category-ads-all → block (optional)
/// 4. `route.final` stays the proxy selector
///
/// Private LAN uses built-in [ip_is_private] so startup never depends on a
/// missing `.srs`. If `singlet-geoip-private.srs` is already on disk (after 更新
/// 规则集), that local rule-set is preferred instead.
///
/// CN/ads rule-sets download through [proxyOutbound] when it is not `direct`.
class RouteDefaults {
  RouteDefaults._();

  static const geoipPrivateTag = 'singlet-geoip-private';
  static const geositeCnTag = 'singlet-geosite-cn';
  static const geoipCnTag = 'singlet-geoip-cn';
  static const geositeAdsTag = 'singlet-geosite-ads';
  static const customTagPrefix = 'singlet-custom-';

  /// jsDelivr mirrors of official SagerNet rule-set branch (reachable in CN).
  static const geoipPrivateUrl =
      'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-private.srs';
  static const geositeCnUrl =
      'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs';
  static const geoipCnUrl =
      'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs';
  static const geositeAdsUrl =
      'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-category-ads-all.srs';

  static const _builtinRuleSetTags = {
    geoipPrivateTag,
    geositeCnTag,
    geoipCnTag,
    geositeAdsTag,
  };

  static bool _isOurRuleSetTag(String tag) =>
      _builtinRuleSetTags.contains(tag) ||
      tag.startsWith(customTagPrefix) ||
      // Legacy pre-Singlet tags (strip on reapply).
      tag.startsWith('singlet-') || tag.startsWith('sbg-');

  /// Apply or strip default + custom rules on [config].
  /// Call after [DnsDefaults.applyToConfig].
  ///
  /// [localRuleSetPaths] maps rule-set tag → absolute `.srs` path (preferred
  /// over remote download). [cacheFilePath] sets experimental.cache_file.path.
  static void applyToConfig(
    Map<String, dynamic> config, {
    required String proxyOutbound,
    BypassRouteSettings route = BypassRouteSettings.defaults,
    Map<String, String> localRuleSetPaths = const {},
    String? cacheFilePath,
  }) {
    _stripOurs(config);

    final proxy = proxyOutbound.isEmpty ? 'direct' : proxyOutbound;
    final downloadDetour = (proxy != 'direct') ? proxy : null;
    final hasCustom = route.customRules.any((r) => r.enabled);
    final needBuiltIn = route.enabled;
    if (!needBuiltIn && !hasCustom) {
      _ensureCacheFile(config, enable: false, path: cacheFilePath);
      return;
    }

    _ensureOutbound(config, type: 'direct', tag: 'direct');
    if (route.blockAds ||
        route.customRules.any(
          (r) => r.enabled && r.outbound == CustomRuleOutbound.block,
        )) {
      _ensureOutbound(config, type: 'block', tag: 'block');
    }

    final ruleSets = <Map<String, dynamic>>[];
    final injected = <Map<String, dynamic>>[];

    // 1) Private / LAN → direct.
    // Prefer on-disk geoip-private; otherwise built-in ip_is_private (no download).
    if (needBuiltIn && route.privateDirect) {
      final privateLocal = localRuleSetPaths[geoipPrivateTag];
      if (privateLocal != null && privateLocal.isNotEmpty) {
        ruleSets.add(
          _ruleSetEntry(
            geoipPrivateTag,
            geoipPrivateUrl,
            downloadDetour,
            privateLocal,
          ),
        );
        injected.add({
          'rule_set': geoipPrivateTag,
          'outbound': 'direct',
        });
      } else {
        injected.add({
          'ip_is_private': true,
          'outbound': 'direct',
        });
      }
    }

    // 2) Custom rules (list order = priority), before CN/ads.
    _appendCustomRuleSets(
      ruleSets: ruleSets,
      injected: injected,
      customs: route.customRules,
      proxyTag: proxy,
    );

    // 3) Built-in CN / ads (local .srs if present, else remote).
    if (needBuiltIn) {
      if (route.chinaDirect) {
        ruleSets.add(
          _ruleSetEntry(
            geositeCnTag,
            geositeCnUrl,
            downloadDetour,
            localRuleSetPaths[geositeCnTag],
          ),
        );
        ruleSets.add(
          _ruleSetEntry(
            geoipCnTag,
            geoipCnUrl,
            downloadDetour,
            localRuleSetPaths[geoipCnTag],
          ),
        );
        injected.addAll([
          {'rule_set': geositeCnTag, 'outbound': 'direct'},
          {'rule_set': geoipCnTag, 'outbound': 'direct'},
        ]);
      }
      if (route.blockAds) {
        ruleSets.add(
          _ruleSetEntry(
            geositeAdsTag,
            geositeAdsUrl,
            downloadDetour,
            localRuleSetPaths[geositeAdsTag],
          ),
        );
        injected.add({'rule_set': geositeAdsTag, 'outbound': 'block'});
      }
    }

    final routeMap = Map<String, dynamic>.from(
      (config['route'] is Map)
          ? Map<String, dynamic>.from(config['route'] as Map)
          : <String, dynamic>{},
    );

    final existingSets = <Map<String, dynamic>>[];
    final rawSets = routeMap['rule_set'];
    if (rawSets is List) {
      for (final item in rawSets) {
        if (item is Map) {
          existingSets.add(Map<String, dynamic>.from(item));
        }
      }
    }
    final mergedSets = [...existingSets, ...ruleSets];
    if (mergedSets.isEmpty) {
      routeMap.remove('rule_set');
    } else {
      routeMap['rule_set'] = mergedSets;
    }

    final rules = <Map<String, dynamic>>[];
    final existingRules = routeMap['rules'];
    if (existingRules is List) {
      for (final item in existingRules) {
        if (item is Map) {
          rules.add(Map<String, dynamic>.from(item));
        }
      }
    }

    // Insert after sniff / hijack-dns (kept at front by DnsDefaults).
    var insertAt = 0;
    while (insertAt < rules.length) {
      final action = '${rules[insertAt]['action'] ?? ''}';
      if (action == 'sniff' || action == 'hijack-dns') {
        insertAt++;
        continue;
      }
      break;
    }

    rules.insertAll(insertAt, injected);
    routeMap['rules'] = rules;
    routeMap.putIfAbsent('final', () => proxy);
    // Process rules need lookup; enable explicitly when any process_name rule is on.
    final hasProcess = route.customRules.any(
      (r) => r.enabled && r.match == CustomRuleMatch.processName,
    );
    if (hasProcess) {
      routeMap['find_process'] = true;
    } else {
      routeMap.remove('find_process');
    }
    config['route'] = routeMap;

    _ensureCacheFile(
      config,
      enable: needBuiltIn || hasCustom,
      path: cacheFilePath,
    );
    if (needBuiltIn) {
      _patchDnsForChina(config, route: route);
    }
  }

  static void _appendCustomRuleSets({
    required List<Map<String, dynamic>> ruleSets,
    required List<Map<String, dynamic>> injected,
    required List<CustomRouteRule> customs,
    required String proxyTag,
  }) {
    var i = 0;
    for (final rule in customs) {
      if (!rule.enabled) continue;
      final headless = rule.toHeadlessRule();
      if (headless == null) continue;
      final tag = '$customTagPrefix$i';
      i++;
      final outbound = switch (rule.outbound) {
        CustomRuleOutbound.proxy => proxyTag,
        CustomRuleOutbound.direct => 'direct',
        CustomRuleOutbound.block => 'block',
      };
      ruleSets.add({
        'type': 'inline',
        'tag': tag,
        'rules': [headless],
      });
      injected.add({
        'rule_set': tag,
        'outbound': outbound,
      });
    }
  }

  static Map<String, dynamic> _ruleSetEntry(
    String tag,
    String url,
    String? downloadDetour,
    String? localPath,
  ) {
    if (localPath != null && localPath.isNotEmpty) {
      return {
        'tag': tag,
        'type': 'local',
        'format': 'binary',
        'path': localPath,
      };
    }
    return {
      'tag': tag,
      'type': 'remote',
      'format': 'binary',
      'url': url,
      'update_interval': '24h',
      if (downloadDetour != null) 'download_detour': downloadDetour,
    };
  }

  static void _stripOurs(Map<String, dynamic> config) {
    final route = config['route'];
    if (route is! Map) return;
    final routeMap = Map<String, dynamic>.from(route);
    // Cleared here; re-applied when process custom rules are present.
    routeMap.remove('find_process');

    final sets = <Map<String, dynamic>>[];
    final rawSets = routeMap['rule_set'];
    if (rawSets is List) {
      for (final item in rawSets) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final tag = '${m['tag'] ?? ''}';
        if (_isOurRuleSetTag(tag)) continue;
        sets.add(m);
      }
    }
    if (sets.isEmpty) {
      routeMap.remove('rule_set');
    } else {
      routeMap['rule_set'] = sets;
    }

    final rules = <Map<String, dynamic>>[];
    final rawRules = routeMap['rules'];
    if (rawRules is List) {
      for (final item in rawRules) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        if (_isOurRouteRule(m)) continue;
        rules.add(m);
      }
    }
    routeMap['rules'] = rules;
    config['route'] = routeMap;

    final dns = config['dns'];
    if (dns is Map) {
      final dnsMap = Map<String, dynamic>.from(dns);
      final dnsRules = <Map<String, dynamic>>[];
      final rawDnsRules = dnsMap['rules'];
      if (rawDnsRules is List) {
        for (final item in rawDnsRules) {
          if (item is! Map) continue;
          final m = Map<String, dynamic>.from(item);
          if (_isOurDnsRule(m)) continue;
          dnsRules.add(m);
        }
      }
      dnsMap['rules'] = dnsRules;
      config['dns'] = dnsMap;
    }
  }

  static bool _isOurRouteRule(Map<String, dynamic> rule) {
    if (rule['ip_is_private'] == true &&
        '${rule['outbound'] ?? ''}' == 'direct' &&
        rule.keys
            .where((k) => k != 'ip_is_private' && k != 'outbound')
            .isEmpty) {
      return true;
    }
    final rs = rule['rule_set'];
    if (rs is String && _isOurRuleSetTag(rs)) return true;
    if (rs is List) {
      final tags = rs.map((e) => '$e').toList();
      if (tags.isNotEmpty && tags.every(_isOurRuleSetTag)) {
        return true;
      }
    }
    return false;
  }

  static bool _isOurDnsRule(Map<String, dynamic> rule) {
    final rs = rule['rule_set'];
    if (rs is String && rs == geositeCnTag) return true;
    if (rs is List && rs.map((e) => '$e').contains(geositeCnTag)) return true;
    return false;
  }

  static void _patchDnsForChina(
    Map<String, dynamic> config, {
    required BypassRouteSettings route,
  }) {
    if (!route.chinaDirect) return;
    final dns = config['dns'];
    if (dns is! Map) return;
    final dnsMap = Map<String, dynamic>.from(dns);
    final servers = dnsMap['servers'];
    String? localTag;
    if (servers is List) {
      for (final s in servers) {
        if (s is! Map) continue;
        final tag = '${s['tag'] ?? ''}';
        if (tag == DnsDefaults.localTag) {
          localTag = tag;
          break;
        }
      }
      if (localTag == null) {
        for (final s in servers) {
          if (s is Map && '${s['tag']}' == DnsDefaults.systemTag) {
            localTag = DnsDefaults.systemTag;
            break;
          }
        }
      }
    }
    if (localTag == null) return;

    final dnsRules = <Map<String, dynamic>>[];
    final raw = dnsMap['rules'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          dnsRules.add(Map<String, dynamic>.from(item));
        }
      }
    }
    dnsRules.add({
      'rule_set': geositeCnTag,
      'server': localTag,
    });
    dnsMap['rules'] = dnsRules;
    config['dns'] = dnsMap;
  }

  static void _ensureOutbound(
    Map<String, dynamic> config, {
    required String type,
    required String tag,
  }) {
    final outs = <Map<String, dynamic>>[];
    final raw = config['outbounds'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final m = Map<String, dynamic>.from(item);
          if ('${m['tag'] ?? ''}' == tag) {
            config['outbounds'] = [
              for (final e in raw)
                if (e is Map) Map<String, dynamic>.from(e),
            ];
            return;
          }
          outs.add(m);
        }
      }
    }
    outs.insert(0, {'type': type, 'tag': tag});
    config['outbounds'] = outs;
  }

  static void _ensureCacheFile(
    Map<String, dynamic> config, {
    required bool enable,
    String? path,
  }) {
    final experimental = Map<String, dynamic>.from(
      (config['experimental'] is Map)
          ? Map<String, dynamic>.from(config['experimental'] as Map)
          : <String, dynamic>{},
    );
    if (enable) {
      final cache = Map<String, dynamic>.from(
        (experimental['cache_file'] is Map)
            ? Map<String, dynamic>.from(experimental['cache_file'] as Map)
            : <String, dynamic>{},
      );
      cache['enabled'] = true;
      if (path != null && path.isNotEmpty) {
        cache['path'] = path;
      }
      experimental['cache_file'] = cache;
    }
    config['experimental'] = experimental;
  }
}
