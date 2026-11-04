import 'app_settings.dart';

/// Default DNS for Singlet sing-box configs.
///
/// Uses **real resolution** (no Clash-style fake-ip). TUN / global capture
/// relies on route `hijack-dns` so port-53 queries enter the DNS module.
///
/// Multiple addresses per role are wrapped in a custom `singlet-group` transport
/// (race / fallback / round_robin) so they are actually used.
class DnsDefaults {
  DnsDefaults._();

  static const localTag = 'local-dns';
  static const lanTag = 'lan-dns';
  static const remoteTag = 'remote-dns';
  static const systemTag = 'system';
  static const groupType = 'singlet-group';

  /// Build a `dns` object from [dns] settings.
  /// [proxyDetour] should be the proxy selector tag (e.g. 节点选择);
  /// when null/`direct`, remote (proxied) resolvers are omitted.
  static Map<String, dynamic> buildDns({
    String? proxyDetour,
    DnsSettings dns = DnsSettings.defaults,
  }) {
    final useRemote =
        proxyDetour != null && proxyDetour.isNotEmpty && proxyDetour != 'direct';

    final servers = <Map<String, dynamic>>[];

    final localAddrs = dns.localAddresses.isEmpty
        ? DnsSettings.defaults.localAddresses
        : dns.localAddresses;
    // Do NOT set detour: "direct" — sing-box rejects detour to an empty
    // direct outbound. Local UDP/DoT dialers already use the default dialer
    // (same as empty direct). TUN excludes these IPs via route_exclude_address.
    final localLogical = _appendAddressGroup(
      servers,
      groupTag: localTag,
      addresses: localAddrs,
      strategy: dns.strategy,
    );

    // Always keep a local system resolver as last-resort for domain dial.
    servers.add({'type': 'local', 'tag': systemTag});
    final localPrimary = localLogical ?? systemTag;

    // Dedicated LAN resolver: private IPs from 直连 DNS only.
    // Must NOT include public DNS — NXDOMAIN from 223.5.5.5 is a "success" and
    // would hide intranet names under race/round_robin/fallback groups.
    final lanPrimary = _appendLanDns(servers, localAddrs) ?? localPrimary;

    String? remotePrimary;
    if (useRemote) {
      final remoteAddrs = dns.remoteAddresses.isEmpty
          ? DnsSettings.defaults.remoteAddresses
          : dns.remoteAddresses;
      remotePrimary = _appendAddressGroup(
        servers,
        groupTag: remoteTag,
        addresses: remoteAddrs,
        strategy: dns.strategy,
        detour: proxyDetour,
      );
    }

    final dnsRules = <Map<String, dynamic>>[
      ..._intranetDnsRules(dns, lanPrimary),
      if (useRemote && remotePrimary != null)
        {
          'clash_mode': 'Direct',
          'server': localPrimary,
        },
    ];

    return {
      'servers': servers,
      'rules': dnsRules,
      'final': remotePrimary ?? localPrimary,
      // ipv4_only: macOS TUN often has no working IPv6 uplink; prefer_ipv4 still
      // returns AAAA and apps like WeChat Moments stick to broken v6 dials.
      'strategy': 'ipv4_only',
      'independent_cache': true,
    };
  }

  /// DNS rules so TUN hijack still resolves intranet / split-horizon names.
  static List<Map<String, dynamic>> _intranetDnsRules(
    DnsSettings dns,
    String lanServer,
  ) {
    final suffixes = <String>{};
    for (final raw in dns.intranetSuffixes) {
      final n = _normalizeSuffix(raw);
      if (n != null) suffixes.add(n);
    }
    return [
      if (suffixes.isNotEmpty)
        {
          'domain_suffix': suffixes.toList()..sort(),
          'server': lanServer,
        },
      // Bare hostnames (printer, nas, gateway) — common on LAN.
      {
        'domain_regex': [r'^[^.]+$'],
        'server': lanServer,
      },
    ];
  }

  static String? _normalizeSuffix(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;
    while (s.startsWith('.')) {
      s = s.substring(1);
    }
    if (s.isEmpty || s.contains('://') || s.contains(' ')) return null;
    return s;
  }

  /// Build [lanTag] from RFC1918 (etc.) addresses in [localAddrs].
  static String? _appendLanDns(
    List<Map<String, dynamic>> servers,
    List<String> localAddrs,
  ) {
    final lanAddrs = <String>[];
    for (final raw in localAddrs) {
      final host = _hostFromAddress(raw);
      if (host != null && _isPrivateIp(host)) {
        lanAddrs.add(raw.trim());
      }
    }
    if (lanAddrs.isEmpty) return null;
    return _appendAddressGroup(
      servers,
      groupTag: lanTag,
      addresses: lanAddrs,
      // Prefer gateway DNS in listed order; don't race public NXDOMAIN.
      strategy: DnsQueryStrategy.fallback,
    );
  }

  static bool _isPrivateIp(String host) {
    if (host.contains(':')) {
      final h = host.toLowerCase();
      return h == '::1' ||
          h.startsWith('fc') ||
          h.startsWith('fd') ||
          h.startsWith('fe80:');
    }
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final nums = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
      nums.add(n);
    }
    final a = nums[0];
    final b = nums[1];
    if (a == 10) return true;
    if (a == 127) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    // CGNAT / Tailscale-ish
    if (a == 100 && b >= 64 && b <= 127) return true;
    if (a == 169 && b == 254) return true;
    return false;
  }

  /// Ensure [config] has dns + hijack-dns route rule (idempotent).
  static void applyToConfig(
    Map<String, dynamic> config, {
    required String proxyDetour,
    DnsSettings dns = DnsSettings.defaults,
  }) {
    final built = buildDns(proxyDetour: proxyDetour, dns: dns);
    config['dns'] = built;

    final route = Map<String, dynamic>.from(
      (config['route'] is Map)
          ? Map<String, dynamic>.from(config['route'] as Map)
          : <String, dynamic>{},
    );

    final rules = <Map<String, dynamic>>[];
    final existing = route['rules'];
    if (existing is List) {
      for (final item in existing) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final action = '${m['action'] ?? ''}';
        // Drop previous DNS-hijack / sniff so we don't duplicate.
        if (action == 'hijack-dns' || action == 'sniff') continue;
        rules.add(m);
      }
    }
    // sing-box 1.11+: sniff first, then hijack all DNS (UDP/TCP 53).
    // System DNS is pointed at a public bait (e.g. 1.1.1.1); packets enter
    // TUN via auto_route and are answered here — not forwarded to that IP.
    rules.insertAll(0, [
      {
        'action': 'sniff',
        'timeout': '300ms',
      },
      {
        'protocol': 'dns',
        'action': 'hijack-dns',
      },
      {
        'port': 53,
        'action': 'hijack-dns',
      },
    ]);
    route['rules'] = rules;
    route.putIfAbsent('final', () => proxyDetour);

    final localPrimary = _logicalTagPresent(built['servers'], localTag)
        ? localTag
        : systemTag;
    route['default_domain_resolver'] = {
      'server': localPrimary,
      'strategy': 'ipv4_only',
    };
    config['route'] = route;
  }

  /// Host/IP literals used by local DNS (for TUN route_exclude_address).
  static List<String> localDnsHosts([DnsSettings dns = DnsSettings.defaults]) {
    final addrs = dns.localAddresses.isEmpty
        ? DnsSettings.defaults.localAddresses
        : dns.localAddresses;
    final hosts = <String>{};
    for (final raw in addrs) {
      final host = _hostFromAddress(raw);
      if (host != null && _looksLikeIp(host)) hosts.add(host);
    }
    return hosts.toList();
  }

  static String? _hostFromAddress(String raw) {
    final server = _serverFromAddress(raw.trim(), tag: '_');
    if (server == null) return null;
    final h = server['server'];
    return h is String && h.isNotEmpty ? h : null;
  }

  static bool _looksLikeIp(String host) {
    if (host.contains(':')) return true; // IPv6
    final parts = host.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  /// Append member server(s) and optional `singlet-group`. Returns logical tag.
  static String? _appendAddressGroup(
    List<Map<String, dynamic>> servers, {
    required String groupTag,
    required List<String> addresses,
    required DnsQueryStrategy strategy,
    String? detour,
  }) {
    final memberTags = <String>[];
    for (var i = 0; i < addresses.length; i++) {
      final memberTag =
          addresses.length == 1 ? groupTag : '$groupTag-$i';
      final server = _serverFromAddress(
        addresses[i],
        tag: memberTag,
        detour: detour,
      );
      if (server == null) continue;
      servers.add(server);
      memberTags.add(memberTag);
    }
    if (memberTags.isEmpty) return null;
    if (memberTags.length == 1) {
      // Single address already tagged as groupTag.
      return memberTags.first;
    }
    servers.add({
      'type': groupType,
      'tag': groupTag,
      'servers': memberTags,
      'strategy': strategy.wireValue,
    });
    return groupTag;
  }

  static bool _logicalTagPresent(dynamic servers, String tag) {
    if (servers is! List) return false;
    for (final item in servers) {
      if (item is Map && '${item['tag'] ?? ''}' == tag) return true;
    }
    return false;
  }

  /// Parse a user address into a sing-box 1.12 typed DNS server.
  ///
  /// Supports: bare IP/host, `udp://` `tcp://` `tls://` `quic://` `https://`
  /// `h3://`, and `local` / `system`.
  static Map<String, dynamic>? _serverFromAddress(
    String raw, {
    required String tag,
    String? detour,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final lower = trimmed.toLowerCase();
    if (lower == 'local' || lower == 'system') {
      return {'type': 'local', 'tag': tag};
    }

    String type;
    String rest;
    if (lower.startsWith('https://')) {
      type = 'https';
      rest = trimmed.substring(8);
    } else if (lower.startsWith('h3://')) {
      type = 'h3';
      rest = trimmed.substring(5);
    } else if (lower.startsWith('tls://')) {
      type = 'tls';
      rest = trimmed.substring(6);
    } else if (lower.startsWith('quic://')) {
      type = 'quic';
      rest = trimmed.substring(7);
    } else if (lower.startsWith('tcp://')) {
      type = 'tcp';
      rest = trimmed.substring(6);
    } else if (lower.startsWith('udp://')) {
      type = 'udp';
      rest = trimmed.substring(6);
    } else {
      type = 'udp';
      rest = trimmed;
    }

    String server;
    String? path;
    final slash = rest.indexOf('/');
    if (slash >= 0) {
      server = rest.substring(0, slash);
      path = rest.substring(slash);
      if (path.isEmpty || path == '/') path = null;
    } else {
      server = rest;
    }

    // Strip brackets from IPv6 literals: [2001:db8::1]:53
    if (server.startsWith('[')) {
      final end = server.indexOf(']');
      if (end > 0) {
        final host = server.substring(1, end);
        final after = server.substring(end + 1);
        if (after.startsWith(':')) {
          final port = int.tryParse(after.substring(1));
          return {
            'type': type,
            'tag': tag,
            'server': host,
            if (port != null) 'server_port': port,
            if (path != null) 'path': path,
            if (detour != null) 'detour': detour,
          };
        }
        server = host;
      }
    } else {
      final colon = server.lastIndexOf(':');
      if (colon > 0 && server.indexOf(':') == colon) {
        final port = int.tryParse(server.substring(colon + 1));
        if (port != null) {
          return {
            'type': type,
            'tag': tag,
            'server': server.substring(0, colon),
            'server_port': port,
            if (path != null) 'path': path,
            if (detour != null) 'detour': detour,
          };
        }
      }
    }

    if (server.isEmpty) return null;

    return {
      'type': type,
      'tag': tag,
      'server': server,
      if (path != null) 'path': path,
      if (detour != null) 'detour': detour,
    };
  }
}
