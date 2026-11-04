import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// How multiple DNS addresses in one role are used (via sing-box `singlet-group`).
enum DnsQueryStrategy {
  /// Query all members concurrently; first success wins.
  race,

  /// Try members in order until one succeeds.
  fallback,

  /// Rotate starting member each query; fall through on failure.
  roundRobin,
}

extension DnsQueryStrategyX on DnsQueryStrategy {
  String get wireValue => switch (this) {
        DnsQueryStrategy.race => 'race',
        DnsQueryStrategy.fallback => 'fallback',
        DnsQueryStrategy.roundRobin => 'round_robin',
      };

  String get label => switch (this) {
        DnsQueryStrategy.race => '竞速',
        DnsQueryStrategy.fallback => '故障转移',
        DnsQueryStrategy.roundRobin => '轮询',
      };

  String get hint => switch (this) {
        DnsQueryStrategy.race => '同时查询，取最快成功的结果',
        DnsQueryStrategy.fallback => '按顺序尝试，失败再换下一个',
        DnsQueryStrategy.roundRobin => '轮流起点，失败则继续下一个',
      };

  static DnsQueryStrategy fromWire(String? raw) {
    switch (raw) {
      case 'fallback':
        return DnsQueryStrategy.fallback;
      case 'round_robin':
      case 'roundRobin':
        return DnsQueryStrategy.roundRobin;
      case 'race':
      default:
        return DnsQueryStrategy.race;
    }
  }
}

/// User-editable DNS preferences (real resolve, no fake-ip).
class DnsSettings {
  const DnsSettings({
    required this.localAddresses,
    required this.remoteAddresses,
    this.strategy = DnsQueryStrategy.race,
  });

  /// Direct / China-side resolvers (used for Direct mode + domain resolve).
  final List<String> localAddresses;

  /// Proxied resolvers (DoH/DoT preferred); each entry may be IP or URL.
  final List<String> remoteAddresses;

  /// Multi-address strategy for each role (local / remote group).
  final DnsQueryStrategy strategy;

  static const defaults = DnsSettings(
    localAddresses: ['223.5.5.5'],
    remoteAddresses: ['https://1.1.1.1/dns-query'],
    strategy: DnsQueryStrategy.race,
  );

  DnsSettings copyWith({
    List<String>? localAddresses,
    List<String>? remoteAddresses,
    DnsQueryStrategy? strategy,
  }) {
    return DnsSettings(
      localAddresses: localAddresses ?? this.localAddresses,
      remoteAddresses: remoteAddresses ?? this.remoteAddresses,
      strategy: strategy ?? this.strategy,
    );
  }

  Map<String, dynamic> toJson() => {
        'localAddresses': localAddresses,
        'remoteAddresses': remoteAddresses,
        'strategy': strategy.wireValue,
      };

  factory DnsSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return DnsSettings(
      localAddresses: _stringList(json['localAddresses'], defaults.localAddresses),
      remoteAddresses:
          _stringList(json['remoteAddresses'], defaults.remoteAddresses),
      strategy: DnsQueryStrategyX.fromWire(json['strategy']?.toString()),
    );
  }

  static List<String> _stringList(dynamic raw, List<String> fallback) {
    if (raw is! List) return List<String>.from(fallback);
    final out = <String>[];
    for (final item in raw) {
      final s = '$item'.trim();
      if (s.isNotEmpty) out.add(s);
    }
    return out.isEmpty ? List<String>.from(fallback) : out;
  }

  /// Parse multiline / comma-separated editor text into addresses.
  static List<String> parseAddressText(String text) {
    final out = <String>[];
    for (final line in text.split(RegExp(r'[\n,;]+'))) {
      final s = line.trim();
      if (s.isNotEmpty) out.add(s);
    }
    return out;
  }

  String localAddressesText() => localAddresses.join('\n');
  String remoteAddressesText() => remoteAddresses.join('\n');
}

/// Local proxy listen ports (0 = disabled for http / socks).
class PortSettings {
  const PortSettings({
    required this.mixedPort,
    required this.httpPort,
    required this.socksPort,
  });

  /// Clash-style mixed (HTTP + SOCKS) port. 0 disables.
  final int mixedPort;

  /// Dedicated HTTP inbound. 0 disables.
  final int httpPort;

  /// Dedicated SOCKS inbound. 0 disables.
  final int socksPort;

  static const defaults = PortSettings(
    mixedPort: 7890,
    httpPort: 0,
    socksPort: 0,
  );

  PortSettings copyWith({
    int? mixedPort,
    int? httpPort,
    int? socksPort,
  }) {
    return PortSettings(
      mixedPort: mixedPort ?? this.mixedPort,
      httpPort: httpPort ?? this.httpPort,
      socksPort: socksPort ?? this.socksPort,
    );
  }

  /// Port used for system HTTP/SOCKS proxy (prefer mixed).
  int get primaryProxyPort {
    if (mixedPort > 0) return mixedPort;
    if (httpPort > 0) return httpPort;
    if (socksPort > 0) return socksPort;
    return defaults.mixedPort;
  }

  Map<String, dynamic> toJson() => {
        'mixedPort': mixedPort,
        'httpPort': httpPort,
        'socksPort': socksPort,
      };

  factory PortSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return PortSettings(
      mixedPort: _port(json['mixedPort'], defaults.mixedPort),
      httpPort: _port(json['httpPort'], defaults.httpPort),
      socksPort: _port(json['socksPort'], defaults.socksPort),
    );
  }

  static int _port(dynamic raw, int fallback) {
    final n = raw is int
        ? raw
        : raw is num
            ? raw.toInt()
            : int.tryParse('$raw');
    if (n == null || n < 0 || n > 65535) return fallback;
    return n;
  }

  /// Build sing-box mixed/http/socks inbounds from these ports.
  List<Map<String, dynamic>> buildInbounds() {
    final out = <Map<String, dynamic>>[];
    if (mixedPort > 0) {
      out.add({
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'listen_port': mixedPort,
      });
    }
    if (httpPort > 0) {
      out.add({
        'type': 'http',
        'tag': 'http-in',
        'listen': '127.0.0.1',
        'listen_port': httpPort,
      });
    }
    if (socksPort > 0) {
      out.add({
        'type': 'socks',
        'tag': 'socks-in',
        'listen': '127.0.0.1',
        'listen_port': socksPort,
      });
    }
    if (out.isEmpty) {
      return defaults.buildInbounds();
    }
    return out;
  }

  /// Replace mixed/http/socks inbounds; keep tun and other types.
  static void applyProxyInbounds(
    Map<String, dynamic> config,
    PortSettings ports,
  ) {
    final kept = <Map<String, dynamic>>[];
    final existing = config['inbounds'];
    if (existing is List) {
      for (final item in existing) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final type = '${m['type'] ?? ''}';
        if (type == 'mixed' || type == 'http' || type == 'socks') continue;
        kept.add(m);
      }
    }
    config['inbounds'] = [...ports.buildInbounds(), ...kept];
  }
}

/// Match field for a user-defined route rule (sing-box headless rule).
enum CustomRuleMatch {
  domainSuffix,
  domain,
  domainKeyword,
  ipCidr,
  processName,
}

extension CustomRuleMatchX on CustomRuleMatch {
  String get wire => switch (this) {
        CustomRuleMatch.domainSuffix => 'domain_suffix',
        CustomRuleMatch.domain => 'domain',
        CustomRuleMatch.domainKeyword => 'domain_keyword',
        CustomRuleMatch.ipCidr => 'ip_cidr',
        CustomRuleMatch.processName => 'process_name',
      };

  String get label => switch (this) {
        CustomRuleMatch.domainSuffix => '域名后缀',
        CustomRuleMatch.domain => '完整域名',
        CustomRuleMatch.domainKeyword => '域名关键词',
        CustomRuleMatch.ipCidr => 'IP CIDR',
        CustomRuleMatch.processName => '进程名',
      };

  String get hint => switch (this) {
        CustomRuleMatch.domainSuffix => 'google.com',
        CustomRuleMatch.domain => 'www.google.com',
        CustomRuleMatch.domainKeyword => 'google',
        CustomRuleMatch.ipCidr => '1.1.1.1/32',
        CustomRuleMatch.processName => 'curl',
      };

  static CustomRuleMatch fromWire(String? raw) {
    switch (raw) {
      case 'domain':
        return CustomRuleMatch.domain;
      case 'domain_keyword':
        return CustomRuleMatch.domainKeyword;
      case 'ip_cidr':
        return CustomRuleMatch.ipCidr;
      case 'process_name':
        return CustomRuleMatch.processName;
      case 'domain_suffix':
      default:
        return CustomRuleMatch.domainSuffix;
    }
  }
}

/// Outbound target for a custom rule.
enum CustomRuleOutbound {
  proxy,
  direct,
  block,
}

extension CustomRuleOutboundX on CustomRuleOutbound {
  String get wire => name;

  String get label => switch (this) {
        CustomRuleOutbound.proxy => '代理',
        CustomRuleOutbound.direct => '直连',
        CustomRuleOutbound.block => '拒绝',
      };

  static CustomRuleOutbound fromWire(String? raw) {
    switch (raw) {
      case 'direct':
        return CustomRuleOutbound.direct;
      case 'block':
        return CustomRuleOutbound.block;
      case 'proxy':
      default:
        return CustomRuleOutbound.proxy;
    }
  }
}

/// One user-defined routing rule (priority = list order).
class CustomRouteRule {
  const CustomRouteRule({
    required this.id,
    required this.match,
    required this.value,
    required this.outbound,
    this.enabled = true,
  });

  final String id;
  final CustomRuleMatch match;
  final String value;
  final CustomRuleOutbound outbound;
  final bool enabled;

  CustomRouteRule copyWith({
    String? id,
    CustomRuleMatch? match,
    String? value,
    CustomRuleOutbound? outbound,
    bool? enabled,
  }) {
    return CustomRouteRule(
      id: id ?? this.id,
      match: match ?? this.match,
      value: value ?? this.value,
      outbound: outbound ?? this.outbound,
      enabled: enabled ?? this.enabled,
    );
  }

  /// Non-empty match payloads for sing-box headless rule.
  List<String> parsedValues() {
    final out = <String>[];
    for (final part in value.split(RegExp(r'[\n,;]+'))) {
      final s = part.trim();
      if (s.isNotEmpty) out.add(s);
    }
    return out;
  }

  Map<String, dynamic>? toHeadlessRule() {
    final values = parsedValues();
    if (values.isEmpty) return null;
    return {match.wire: values};
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'match': match.wire,
        'value': value,
        'outbound': outbound.wire,
        'enabled': enabled,
      };

  factory CustomRouteRule.fromJson(Map<String, dynamic> json) {
    return CustomRouteRule(
      id: '${json['id'] ?? ''}'.isNotEmpty
          ? '${json['id']}'
          : DateTime.now().microsecondsSinceEpoch.toString(),
      match: CustomRuleMatchX.fromWire(json['match']?.toString()),
      value: '${json['value'] ?? ''}',
      outbound: CustomRuleOutboundX.fromWire(json['outbound']?.toString()),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
    );
  }
}

/// Built-in routing: private / CN direct (+ optional ads block) via rule-sets.
class BypassRouteSettings {
  const BypassRouteSettings({
    this.enabled = true,
    this.privateDirect = true,
    this.chinaDirect = true,
    this.blockAds = false,
    this.customRules = const [],
  });

  /// Master switch for injecting default rules + remote rule-sets.
  final bool enabled;

  /// Private / LAN → direct (`ip_is_private`, or local geoip-private.srs).
  final bool privateDirect;

  /// geosite-cn + geoip-cn → direct; CN domains use local DNS.
  final bool chinaDirect;

  /// geosite category-ads-all → block.
  final bool blockAds;

  /// User rules (higher priority than CN/ads; after private IP).
  final List<CustomRouteRule> customRules;

  static const defaults = BypassRouteSettings();

  BypassRouteSettings copyWith({
    bool? enabled,
    bool? privateDirect,
    bool? chinaDirect,
    bool? blockAds,
    List<CustomRouteRule>? customRules,
  }) {
    return BypassRouteSettings(
      enabled: enabled ?? this.enabled,
      privateDirect: privateDirect ?? this.privateDirect,
      chinaDirect: chinaDirect ?? this.chinaDirect,
      blockAds: blockAds ?? this.blockAds,
      customRules: customRules ?? this.customRules,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'privateDirect': privateDirect,
        'chinaDirect': chinaDirect,
        'blockAds': blockAds,
        'customRules': [for (final r in customRules) r.toJson()],
      };

  factory BypassRouteSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    final rawRules = json['customRules'];
    final customs = <CustomRouteRule>[];
    if (rawRules is List) {
      for (final item in rawRules) {
        if (item is Map) {
          customs.add(CustomRouteRule.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return BypassRouteSettings(
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      privateDirect:
          json['privateDirect'] is bool ? json['privateDirect'] as bool : true,
      chinaDirect:
          json['chinaDirect'] is bool ? json['chinaDirect'] as bool : true,
      blockAds: json['blockAds'] is bool ? json['blockAds'] as bool : false,
      customRules: customs,
    );
  }
}

class AppSettings {
  const AppSettings({
    required this.dns,
    this.ports = PortSettings.defaults,
    this.route = BypassRouteSettings.defaults,
  });

  final DnsSettings dns;
  final PortSettings ports;
  final BypassRouteSettings route;

  static const defaults = AppSettings(
    dns: DnsSettings.defaults,
    ports: PortSettings.defaults,
    route: BypassRouteSettings.defaults,
  );

  AppSettings copyWith({
    DnsSettings? dns,
    PortSettings? ports,
    BypassRouteSettings? route,
  }) =>
      AppSettings(
        dns: dns ?? this.dns,
        ports: ports ?? this.ports,
        route: route ?? this.route,
      );

  Map<String, dynamic> toJson() => {
        'dns': dns.toJson(),
        'ports': ports.toJson(),
        'route': route.toJson(),
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final dnsRaw = json['dns'];
    final portsRaw = json['ports'];
    final routeRaw = json['route'];
    return AppSettings(
      dns: DnsSettings.fromJson(
        dnsRaw is Map ? Map<String, dynamic>.from(dnsRaw) : null,
      ),
      ports: PortSettings.fromJson(
        portsRaw is Map ? Map<String, dynamic>.from(portsRaw) : null,
      ),
      route: BypassRouteSettings.fromJson(
        routeRaw is Map ? Map<String, dynamic>.from(routeRaw) : null,
      ),
    );
  }
}

/// Persists [AppSettings] under Application Support.
class AppSettingsStore {
  static const fileName = 'app-settings.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }

  Future<AppSettings> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return AppSettings.defaults;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return AppSettings.defaults;
      return AppSettings.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return AppSettings.defaults;
    }
  }

  Future<void> save(AppSettings settings) async {
    final file = await _file();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
  }
}
