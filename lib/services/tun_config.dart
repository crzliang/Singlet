import 'dart:convert';
import 'dart:io';

import 'app_settings.dart';
import 'dns_defaults.dart';
import 'route_defaults.dart';
import 'rule_set_store.dart';

/// Inject / strip sing-box TUN inbound for helper-side root start.
class TunConfig {
  static const tunTag = 'tun-in';
  static const defaultMixedPort = 7890;

  /// TUN addresses (sing-box 1.12 `address`).
  static const tunInet4 = '172.19.0.1/30';
  static const tunInet6 = 'fdfe:dcba:9876::1/126';

  /// Public DNS bait for macOS system resolver.
  ///
  /// LAN DHCP DNS never enters TUN, so we point the OS at a public resolver
  /// (UDP/53). `auto_route` pulls those packets into TUN and `hijack-dns`
  /// answers them via sing-box DNS — the real 1.1.1.1 UDP server is never
  /// contacted. DoH (`https://1.1.1.1/dns-query`) stays a separate path.
  static const tunDnsServers = <String>['1.1.1.1'];

  /// Prefer mixed, then http, then socks listen_port (fallback settings default).
  static Future<int> mixedPortFromConfig(String path) async {
    try {
      final raw = jsonDecode(await File(path).readAsString());
      if (raw is! Map) return defaultMixedPort;
      final inbounds = raw['inbounds'];
      if (inbounds is! List) return defaultMixedPort;
      int? mixed;
      int? http;
      int? socks;
      for (final item in inbounds) {
        if (item is! Map) continue;
        final type = '${item['type'] ?? ''}';
        final p = item['listen_port'];
        final port = p is int ? p : (p is num ? p.toInt() : null);
        if (port == null || port <= 0) continue;
        if (type == 'mixed') mixed = port;
        if (type == 'http') http = port;
        if (type == 'socks') socks = port;
      }
      return mixed ?? http ?? socks ?? defaultMixedPort;
    } catch (_) {}
    return defaultMixedPort;
  }

  /// Write a sibling `*-tun.json` with tun inbound + auto_detect_interface.
  static Future<String> writeTunVariant(String sourcePath) async {
    final src = File(sourcePath);
    final decoded = jsonDecode(await src.readAsString());
    if (decoded is! Map) {
      throw StateError('config root is not an object');
    }
    final map = Map<String, dynamic>.from(decoded);
    final inbounds = <Map<String, dynamic>>[];
    final existing = map['inbounds'];
    if (existing is List) {
      for (final item in existing) {
        if (item is Map) {
          final m = Map<String, dynamic>.from(item);
          if (m['tag'] == tunTag || m['type'] == 'tun') continue;
          inbounds.add(m);
        }
      }
    }
    final settings = await AppSettingsStore().load();
    final dns = settings.dns;
    // Exclude local DNS IPs from TUN so resolver traffic does not loop
    // through hijack-dns (and so we don't need illegal detour:"direct").
    final exclude = <String>[
      for (final host in DnsDefaults.localDnsHosts(dns))
        host.contains(':') ? host : '$host/32',
    ];

    inbounds.insert(0, {
      'type': 'tun',
      'tag': tunTag,
      'address': [tunInet4, tunInet6],
      // 1500 avoids macOS utun + large-MTU UDP DNS oddities.
      'mtu': 1500,
      'auto_route': true,
      'strict_route': true,
      // mixed: system TCP + gVisor UDP — DNS (UDP/53) reply path is reliable.
      'stack': 'mixed',
      if (exclude.isNotEmpty) 'route_exclude_address': exclude,
    });
    map['inbounds'] = inbounds;

    final route = Map<String, dynamic>.from(
      (map['route'] is Map)
          ? Map<String, dynamic>.from(map['route'] as Map)
          : <String, dynamic>{},
    );
    route['auto_detect_interface'] = true;
    map['route'] = route;

    // Always (re)inject real DNS + sniff + hijack-dns + default rules.
    final finalTag = '${route['final'] ?? 'direct'}';
    DnsDefaults.applyToConfig(map, proxyDetour: finalTag, dns: dns);
    // path_provider can be unavailable in unit tests — fall back to remote sets.
    Map<String, String> locals = const {};
    String? cachePath;
    try {
      final store = RuleSetStore();
      locals = await store.localPathsFor(settings.route);
      cachePath = await store.cacheDbPath();
    } catch (_) {}
    RouteDefaults.applyToConfig(
      map,
      proxyOutbound: finalTag,
      route: settings.route,
      localRuleSetPaths: locals,
      cacheFilePath: cachePath,
    );
    final routeAfter = Map<String, dynamic>.from(map['route'] as Map);
    routeAfter['auto_detect_interface'] = true;
    map['route'] = routeAfter;

    final outPath = sourcePath.endsWith('.json')
        ? '${sourcePath.substring(0, sourcePath.length - 5)}-tun.json'
        : '$sourcePath-tun.json';
    final cleaned = _stripUnknownTopLevel(map);
    await File(outPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(cleaned),
    );
    return outPath;
  }

  static Map<String, dynamic> _stripUnknownTopLevel(Map<String, dynamic> map) {
    const allowed = {
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
    return Map<String, dynamic>.fromEntries(
      map.entries.where(
        (e) => allowed.contains(e.key) && !e.key.startsWith('_'),
      ),
    );
  }
}
