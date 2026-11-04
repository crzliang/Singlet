import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';

import '../models/subscription_profile.dart';
import 'app_settings.dart';
import 'config_store.dart';
import 'dns_defaults.dart';
import 'route_defaults.dart';
import 'rule_set_store.dart';
import 'share_link_parser.dart';

/// Clash YAML subscription import → runnable sing-box JSON draft.
class SubscriptionService {
  SubscriptionService({
    ConfigStore? store,
    AppSettingsStore? settingsStore,
    http.Client? client,
  })  : _store = store ?? ConfigStore(),
        _settingsStore = settingsStore ?? AppSettingsStore(),
        _client = client ?? http.Client();

  final ConfigStore _store;
  final AppSettingsStore _settingsStore;
  final http.Client _client;

  static const draftFileName = 'from-clash-draft.json';

  /// Smart import: http(s) 订阅 / 分享链接 / sing-box JSON / Clash YAML 文本.
  Future<SubscriptionImportResult> importFromText(
    String text, {
    String configFileName = draftFileName,
    String? profileName,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const SubscriptionImportResult(ok: false, message: '内容为空');
    }

    // First line may be a share link even if pasted with trailing blank lines.
    final firstLine = trimmed.split(RegExp(r'\r?\n')).first.trim();
    if (ShareLinkParser.looksLikeShareLink(firstLine)) {
      return importShareLink(
        firstLine,
        configFileName: configFileName,
        profileName: profileName,
      );
    }

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      // Bare URL on first line (subscription).
      final url = firstLine.contains(RegExp(r'\s')) ? trimmed : firstLine;
      if (ShareLinkParser.looksLikeShareLink(url)) {
        return importShareLink(
          url,
          configFileName: configFileName,
          profileName: profileName,
        );
      }
      return importFromUrl(
        url,
        configFileName: configFileName,
        profileName: profileName,
      );
    }

    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return importSingBoxJson(
        trimmed,
        configFileName: configFileName,
        profileName: profileName,
      );
    }

    return importClashYamlText(
      trimmed,
      configFileName: configFileName,
      profileName: profileName,
    );
  }

  Future<SubscriptionImportResult> importShareLink(
    String link, {
    String configFileName = draftFileName,
    String? profileName,
  }) async {
    final proxy = ShareLinkParser.parse(link);
    if (proxy == null) {
      return const SubscriptionImportResult(
        ok: false,
        message: '无法解析分享链接（支持 ss / vmess / vless / trojan / hy2）',
      );
    }
    try {
      final settings = await _settingsStore.load();
      final converted = _toSingBoxDraftFromProxyMaps(
        [proxy],
        dns: settings.dns,
        ports: settings.ports,
        route: settings.route,
      );
      if (converted.mappedCount == 0) {
        return SubscriptionImportResult(
          ok: false,
          message:
              '分享链接类型暂不支持：${proxy['type'] ?? 'unknown'}',
        );
      }
      final name = profileName ??
          '${proxy['name'] ?? '单节点'}'.trim();
      final path = await _store.writeGeneratedConfig(
        const JsonEncoder.withIndent('  ').convert(converted.config),
        name: configFileName,
        meta: {
          'mappedCount': converted.mappedCount,
          'proxyTotal': converted.proxyTotal,
          'source': 'share-link',
        },
      );
      return SubscriptionImportResult(
        ok: true,
        message: '已导入单节点：${proxy['name'] ?? name}',
        profileName: name.isEmpty ? configFileName : name,
        configPath: path,
        proxyCount: converted.proxyTotal,
        mappedCount: converted.mappedCount,
        unmappedCount: 0,
      );
    } catch (e) {
      return SubscriptionImportResult(ok: false, message: '$e');
    }
  }

  Future<SubscriptionImportResult> importSingBoxJson(
    String raw, {
    String configFileName = draftFileName,
    String? profileName,
  }) async {
    try {
      final decoded = jsonDecode(raw);
      Map<String, dynamic> config;
      var proxyCount = 0;
      var source = 'singbox-json';

      if (decoded is List) {
        final outs = <Map<String, dynamic>>[];
        for (final item in decoded) {
          if (item is Map) outs.add(Map<String, dynamic>.from(item));
        }
        if (outs.isEmpty) {
          return const SubscriptionImportResult(
            ok: false,
            message: 'JSON 数组为空',
          );
        }
        final settings = await _settingsStore.load();
        final converted = _wrapOutbounds(
          outs,
          dns: settings.dns,
          ports: settings.ports,
          route: settings.route,
        );
        config = converted.config;
        proxyCount = converted.mappedCount;
        source = 'singbox-outbounds';
      } else if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        if (map['outbounds'] is List) {
          config = map;
          final settings = await _settingsStore.load();
          _ensureRuntimeShell(config, ports: settings.ports);
          final route = config['route'];
          final finalTag = route is Map
              ? '${route['final'] ?? 'direct'}'
              : 'direct';
          DnsDefaults.applyToConfig(
            config,
            proxyDetour: finalTag,
            dns: settings.dns,
          );
          await applyRouteDefaultsWithLocals(
            config,
            proxyOutbound: finalTag,
            route: settings.route,
          );
          proxyCount = _countProxyOutbounds(config['outbounds']);
        } else if (map['type'] != null &&
            (map['server'] != null || map['type'] == 'direct')) {
          final settings = await _settingsStore.load();
          final converted = _wrapOutbounds(
            [map],
            dns: settings.dns,
            ports: settings.ports,
            route: settings.route,
          );
          config = converted.config;
          proxyCount = converted.mappedCount;
          source = 'singbox-outbound';
        } else {
          return const SubscriptionImportResult(
            ok: false,
            message: 'JSON 既不是完整 sing-box 配置，也不是 outbound',
          );
        }
      } else {
        return const SubscriptionImportResult(
          ok: false,
          message: 'JSON 根节点无效',
        );
      }

      final path = await _store.writeGeneratedConfig(
        const JsonEncoder.withIndent('  ').convert(config),
        name: configFileName,
        meta: {
          'mappedCount': proxyCount,
          'proxyTotal': proxyCount,
          'source': source,
        },
      );
      return SubscriptionImportResult(
        ok: true,
        message: '已导入 sing-box JSON（$proxyCount 个节点）',
        profileName: profileName ?? configFileName,
        configPath: path,
        proxyCount: proxyCount,
        mappedCount: proxyCount,
        unmappedCount: 0,
      );
    } catch (e) {
      return SubscriptionImportResult(ok: false, message: 'JSON 解析失败: $e');
    }
  }

  Future<SubscriptionImportResult> importClashYamlText(
    String body, {
    String configFileName = draftFileName,
    String? profileName,
    SubscriptionUserInfo? userInfo,
  }) async {
    try {
      var text = _stripBom(body);
      if (!_looksLikeYaml(text)) {
        final decoded = _tryDecodeSubscriptionPayload(text);
        if (decoded != null) text = decoded;
      }

      if (!_looksLikeYaml(text) && !_tryParseYamlMap(text)) {
        final preview = text.trimLeft();
        final snip =
            preview.length > 40 ? '${preview.substring(0, 40)}…' : preview;
        return SubscriptionImportResult(
          ok: false,
          message: '无法识别内容（开头: $snip）',
        );
      }

      final doc = loadYaml(text);
      if (doc is! YamlMap) {
        return const SubscriptionImportResult(
          ok: false,
          message: 'YAML 根节点不是 map',
        );
      }

      final settings = await _settingsStore.load();
      final converted = _toSingBoxDraft(
        doc,
        dns: settings.dns,
        ports: settings.ports,
        route: settings.route,
      );
      final path = await _store.writeGeneratedConfig(
        const JsonEncoder.withIndent('  ').convert(converted.config),
        name: configFileName,
        meta: {
          'mappedCount': converted.mappedCount,
          'proxyTotal': converted.proxyTotal,
          'unmappedCount': converted.unmappedCount,
          'unmappedTypes': converted.unmappedTypes,
          'source': 'clash-yaml',
        },
      );

      return SubscriptionImportResult(
        ok: true,
        message:
            '已生成配置：映射 ${converted.mappedCount}/${converted.proxyTotal}'
            '${converted.unmappedCount > 0 ? '，跳过 ${converted.unmappedCount}' : ''}',
        profileName: profileName ?? configFileName,
        configPath: path,
        proxyCount: converted.proxyTotal,
        mappedCount: converted.mappedCount,
        unmappedCount: converted.unmappedCount,
        unmappedTypes: converted.unmappedTypes,
        userInfo: userInfo,
      );
    } catch (e) {
      return SubscriptionImportResult(ok: false, message: '$e');
    }
  }

  Future<SubscriptionImportResult> importFromUrl(
    String url, {
    String configFileName = draftFileName,
    String? profileName,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return const SubscriptionImportResult(ok: false, message: 'URL 为空');
    }
    if (!(trimmed.startsWith('http://') || trimmed.startsWith('https://'))) {
      return const SubscriptionImportResult(
        ok: false,
        message: '仅支持 http(s) 订阅链接',
      );
    }

    try {
      final res = await _client
          .get(
            Uri.parse(trimmed),
            headers: {
              'User-Agent': 'clash.meta',
              'Accept': 'text/yaml, text/plain, */*',
            },
          )
          .timeout(const Duration(seconds: 25));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return SubscriptionImportResult(
          ok: false,
          message: 'HTTP ${res.statusCode}',
        );
      }

      final userInfo = parseSubscriptionUserInfo(res.headers);
      var body = utf8.decode(res.bodyBytes, allowMalformed: true);
      return importClashYamlText(
        body,
        configFileName: configFileName,
        profileName: profileName,
        userInfo: userInfo,
      );
    } catch (e) {
      return SubscriptionImportResult(ok: false, message: '$e');
    }
  }

  /// `subscription-userinfo: upload=…; download=…; total=…; expire=…`
  static SubscriptionUserInfo? parseSubscriptionUserInfo(
    Map<String, String> headers,
  ) {
    String? raw;
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == 'subscription-userinfo') {
        raw = e.value;
        break;
      }
    }
    if (raw == null || raw.trim().isEmpty) return null;

    int? upload;
    int? download;
    int? total;
    int? expire;
    for (final part in raw.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length < 2) continue;
      final key = kv.first.trim().toLowerCase();
      final val = int.tryParse(kv.sublist(1).join('=').trim());
      switch (key) {
        case 'upload':
          upload = val;
        case 'download':
          download = val;
        case 'total':
          total = val;
        case 'expire':
          expire = val;
      }
    }
    if (upload == null &&
        download == null &&
        total == null &&
        expire == null) {
      return null;
    }
    return SubscriptionUserInfo(
      upload: upload,
      download: download,
      total: total,
      expire: expire,
    );
  }

  String _stripBom(String s) {
    if (s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF) {
      return s.substring(1);
    }
    return s;
  }

  bool _looksLikeYaml(String s) {
    final t = s.trimLeft();
    if (t.isEmpty) return false;
    if (t.startsWith('<!DOCTYPE') ||
        t.startsWith('<!doctype') ||
        t.startsWith('<html') ||
        t.startsWith('<HTML')) {
      return false;
    }
    const keys = [
      'proxies:',
      'proxy-groups:',
      'proxy-providers:',
      'port:',
      'mixed-port:',
      'socks-port:',
      'redir-port:',
      'tproxy-port:',
      'allow-lan:',
      'mode:',
      'dns:',
      'rules:',
      'rule-providers:',
      'external-controller:',
    ];
    for (final k in keys) {
      if (t.startsWith(k)) return true;
    }
    final head = t.length > 4000 ? t.substring(0, 4000) : t;
    return head.contains('\nproxies:') ||
        head.contains('\nproxy-groups:') ||
        head.contains('\nmixed-port:') ||
        head.contains('\nrules:');
  }

  bool _tryParseYamlMap(String s) {
    try {
      return loadYaml(s) is YamlMap;
    } catch (_) {
      return false;
    }
  }

  String? _tryDecodeSubscriptionPayload(String raw) {
    final trimmed = raw.trim();
    try {
      final decoded = utf8.decode(base64.decode(_padBase64(trimmed)));
      if (_looksLikeYaml(decoded) || _tryParseYamlMap(decoded)) {
        return decoded;
      }
      if (_looksLikeShareLinks(decoded)) {
        return _shareLinksToStubYaml(decoded);
      }
    } catch (_) {}
    if (_looksLikeShareLinks(trimmed)) {
      return _shareLinksToStubYaml(trimmed);
    }
    return null;
  }

  bool _looksLikeShareLinks(String s) {
    final line = s.trimLeft();
    return line.startsWith('vmess://') ||
        line.startsWith('ss://') ||
        line.startsWith('trojan://') ||
        line.startsWith('vless://') ||
        line.startsWith('hysteria2://') ||
        line.startsWith('hy2://') ||
        line.contains('\nvmess://') ||
        line.contains('\nss://') ||
        line.contains('\nvless://');
  }

  String _shareLinksToStubYaml(String decoded) {
    final lines = decoded
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.contains('://'))
        .take(128)
        .toList();
    final buf = StringBuffer('proxies:\n');
    var i = 0;
    for (final link in lines) {
      final scheme = link.split('://').first.toLowerCase();
      buf.writeln('  - name: "imported-$i"');
      buf.writeln('    type: $scheme');
      buf.writeln('    server: 127.0.0.1');
      buf.writeln('    port: 1');
      i++;
    }
    return buf.toString();
  }

  String _padBase64(String s) {
    final mod = s.length % 4;
    if (mod == 0) return s;
    return s.padRight(s.length + (4 - mod), '=');
  }

  _ConvertedDraft _toSingBoxDraftFromProxyMaps(
    List<Map<String, dynamic>> proxies, {
    DnsSettings dns = DnsSettings.defaults,
    PortSettings ports = PortSettings.defaults,
    BypassRouteSettings route = BypassRouteSettings.defaults,
  }) {
    final outbounds = <Map<String, dynamic>>[
      {'type': 'direct', 'tag': 'direct'},
      {'type': 'block', 'tag': 'block'},
    ];
    final tagByName = <String, String>{
      'DIRECT': 'direct',
      'REJECT': 'block',
    };
    final tags = <String>[];
    final unmappedTypes = <String, int>{};
    var proxyTotal = 0;
    var mappedCount = 0;

    var i = 0;
    for (final p in proxies) {
      proxyTotal++;
      final name = '${p['name'] ?? 'proxy-$i'}';
      final type = '${p['type'] ?? ''}';
      final tag = _uniqueTag(_safeTag(name), tagByName);
      final mapped = _mapProxy(p, tag, type);
      if (mapped != null) {
        outbounds.add(mapped);
        tagByName[name] = tag;
        tags.add(tag);
        mappedCount++;
      } else {
        final key = type.isEmpty ? 'unknown' : type.toLowerCase();
        unmappedTypes[key] = (unmappedTypes[key] ?? 0) + 1;
      }
      i++;
      if (i >= 256) break;
    }

    return _finishDraft(
      outbounds: outbounds,
      tags: tags,
      tagByName: tagByName,
      groupSource: null,
      proxyTotal: proxyTotal,
      mappedCount: mappedCount,
      unmappedTypes: unmappedTypes,
      dns: dns,
      ports: ports,
      route: route,
    );
  }

  _ConvertedDraft _wrapOutbounds(
    List<Map<String, dynamic>> proxyOutbounds, {
    required DnsSettings dns,
    PortSettings ports = PortSettings.defaults,
    BypassRouteSettings route = BypassRouteSettings.defaults,
  }) {
    final outbounds = <Map<String, dynamic>>[
      {'type': 'direct', 'tag': 'direct'},
      {'type': 'block', 'tag': 'block'},
    ];
    final tags = <String>[];
    final used = <String>{'direct', 'block'};
    var i = 0;
    for (final raw in proxyOutbounds) {
      final o = Map<String, dynamic>.from(raw);
      final type = '${o['type'] ?? ''}';
      if (type == 'direct' || type == 'block' || type == 'dns') continue;
      var tag = '${o['tag'] ?? type}-$i';
      if (tag.isEmpty) tag = 'proxy-$i';
      tag = _safeTag(tag);
      if (used.contains(tag)) {
        tag = _uniqueTag(tag, {for (final t in used) t: t});
      }
      o['tag'] = tag;
      used.add(tag);
      outbounds.add(o);
      if (type != 'selector' && type != 'urltest') {
        tags.add(tag);
      }
      i++;
    }
    return _finishDraft(
      outbounds: outbounds,
      tags: tags,
      tagByName: {for (final t in tags) t: t},
      groupSource: null,
      proxyTotal: tags.length,
      mappedCount: tags.length,
      unmappedTypes: const {},
      dns: dns,
      ports: ports,
      route: route,
    );
  }

  void _ensureRuntimeShell(
    Map<String, dynamic> config, {
    PortSettings ports = PortSettings.defaults,
  }) {
    config.putIfAbsent('log', () => {'level': 'info', 'timestamp': true});
    PortSettings.applyProxyInbounds(config, ports);
    final experimental = Map<String, dynamic>.from(
      (config['experimental'] is Map)
          ? Map<String, dynamic>.from(config['experimental'] as Map)
          : <String, dynamic>{},
    );
    final clashApi = Map<String, dynamic>.from(
      (experimental['clash_api'] is Map)
          ? Map<String, dynamic>.from(experimental['clash_api'] as Map)
          : <String, dynamic>{},
    );
    clashApi.putIfAbsent(
      'external_controller',
      () => '127.0.0.1:9090',
    );
    clashApi.putIfAbsent('access_control_allow_private_network', () => true);
    experimental['clash_api'] = clashApi;
    config['experimental'] = experimental;
    final route = Map<String, dynamic>.from(
      (config['route'] is Map)
          ? Map<String, dynamic>.from(config['route'] as Map)
          : <String, dynamic>{},
    );
    route.putIfAbsent('final', () {
      final outs = config['outbounds'];
      if (outs is List) {
        for (final o in outs) {
          if (o is Map &&
              (o['type'] == 'selector' || o['type'] == 'urltest')) {
            return '${o['tag']}';
          }
        }
        for (final o in outs) {
          if (o is Map &&
              o['type'] != 'direct' &&
              o['type'] != 'block' &&
              o['type'] != 'dns') {
            return '${o['tag']}';
          }
        }
      }
      return 'direct';
    });
    config['route'] = route;
  }

  int _countProxyOutbounds(dynamic outbounds) {
    if (outbounds is! List) return 0;
    var n = 0;
    for (final o in outbounds) {
      if (o is! Map) continue;
      final type = '${o['type'] ?? ''}';
      if (type == 'direct' ||
          type == 'block' ||
          type == 'dns' ||
          type == 'selector' ||
          type == 'urltest') {
        continue;
      }
      n++;
    }
    return n;
  }

  _ConvertedDraft _toSingBoxDraft(
    YamlMap clash, {
    DnsSettings dns = DnsSettings.defaults,
    PortSettings ports = PortSettings.defaults,
    BypassRouteSettings route = BypassRouteSettings.defaults,
  }) {
    final outbounds = <Map<String, dynamic>>[
      {'type': 'direct', 'tag': 'direct'},
      {'type': 'block', 'tag': 'block'},
    ];
    final tagByName = <String, String>{
      'DIRECT': 'direct',
      'REJECT': 'block',
    };
    final tags = <String>[];
    final unmappedTypes = <String, int>{};
    var proxyTotal = 0;
    var mappedCount = 0;

    final proxies = clash['proxies'];
    if (proxies is YamlList) {
      var i = 0;
      for (final p in proxies) {
        if (p is! YamlMap) continue;
        proxyTotal++;
        final name = '${p['name'] ?? 'proxy-$i'}';
        final type = '${p['type'] ?? ''}';
        final tag = _uniqueTag(_safeTag(name), tagByName);
        final mapped = _mapProxy(Map<String, dynamic>.from(p), tag, type);
        if (mapped != null) {
          outbounds.add(mapped);
          tagByName[name] = tag;
          tags.add(tag);
          mappedCount++;
        } else {
          final key = type.isEmpty ? 'unknown' : type.toLowerCase();
          unmappedTypes[key] = (unmappedTypes[key] ?? 0) + 1;
        }
        i++;
        if (i >= 256) break;
      }
    }

    return _finishDraft(
      outbounds: outbounds,
      tags: tags,
      tagByName: tagByName,
      groupSource: clash['proxy-groups'],
      proxyTotal: proxyTotal,
      mappedCount: mappedCount,
      unmappedTypes: unmappedTypes,
      dns: dns,
      ports: ports,
      route: route,
    );
  }

  _ConvertedDraft _finishDraft({
    required List<Map<String, dynamic>> outbounds,
    required List<String> tags,
    required Map<String, String> tagByName,
    required dynamic groupSource,
    required int proxyTotal,
    required int mappedCount,
    required Map<String, int> unmappedTypes,
    required DnsSettings dns,
    PortSettings ports = PortSettings.defaults,
    BypassRouteSettings route = BypassRouteSettings.defaults,
  }) {
    // Clash proxy-groups → sing-box selector / urltest.
    final groupTags = <String>[];
    final pendingGroups = <Map>[];
    if (groupSource is YamlList || groupSource is List) {
      for (final g in groupSource as List) {
        if (g is! Map) continue;
        final gName = '${g['name'] ?? ''}';
        if (gName.isEmpty) continue;
        final gTag = _uniqueTag(_safeTag(gName), tagByName);
        tagByName[gName] = gTag;
        pendingGroups.add(g);
      }
      for (final g in pendingGroups) {
        final gName = '${g['name'] ?? ''}';
        final gType = '${g['type'] ?? 'select'}'.toLowerCase();
        final gTag = tagByName[gName]!;
        final members = <String>[];
        final plist = g['proxies'];
        if (plist is YamlList || plist is List) {
          for (final m in plist as List) {
            final n = '$m';
            final mapped = tagByName[n];
            if (mapped != null) {
              members.add(mapped);
            } else if (n.toUpperCase() == 'DIRECT') {
              members.add('direct');
            } else if (n.toUpperCase() == 'REJECT') {
              members.add('block');
            }
          }
        }
        if (members.isEmpty && tags.isNotEmpty) {
          members.addAll(tags);
        }
        if (members.isEmpty) continue;

        if (gType == 'url-test' ||
            gType == 'fallback' ||
            gType == 'load-balance') {
          outbounds.add({
            'type': 'urltest',
            'tag': gTag,
            'outbounds': members,
            'url': '${g['url'] ?? 'https://www.gstatic.com/generate_204'}',
            'interval': _durationFromClash(g['interval']),
          });
        } else {
          outbounds.add({
            'type': 'selector',
            'tag': gTag,
            'outbounds': members,
            'default': members.first,
          });
        }
        groupTags.add(gTag);
      }
    }

    if (groupTags.isEmpty && tags.isNotEmpty) {
      outbounds.add({
        'type': 'selector',
        'tag': 'proxy',
        'outbounds': [...tags, 'direct'],
        'default': tags.first,
      });
      groupTags.add('proxy');
    }

    final finalTag = groupTags.isNotEmpty
        ? groupTags.first
        : (tags.isNotEmpty ? tags.first : 'direct');

    final config = <String, dynamic>{
      'log': {'level': 'info', 'timestamp': true},
      'inbounds': ports.buildInbounds(),
      'outbounds': outbounds,
      'route': {'final': finalTag},
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:9090',
          'access_control_allow_private_network': true,
        }
      },
    };

    DnsDefaults.applyToConfig(config, proxyDetour: finalTag, dns: dns);
    RouteDefaults.applyToConfig(
      config,
      proxyOutbound: finalTag,
      route: route,
    );

    return _ConvertedDraft(
      config: config,
      proxyTotal: proxyTotal,
      mappedCount: mappedCount,
      unmappedCount: proxyTotal - mappedCount,
      unmappedTypes: unmappedTypes,
    );
  }

  String _durationFromClash(dynamic interval) {
    if (interval is int) return '${interval}s';
    if (interval is num) return '${interval.toInt()}s';
    final s = '$interval';
    if (s.endsWith('s') || s.endsWith('m')) return s;
    final n = int.tryParse(s);
    return n != null ? '${n}s' : '5m';
  }

  String _uniqueTag(String base, Map<String, String> existing) {
    final used = existing.values.toSet();
    if (!used.contains(base)) return base;
    var i = 2;
    while (used.contains('${base}_$i')) {
      i++;
    }
    return '${base}_$i';
  }

  Map<String, dynamic>? _mapProxy(Map p, String tag, String type) {
    switch (type.toLowerCase()) {
      case 'socks5':
      case 'socks':
        return {
          'type': 'socks',
          'tag': tag,
          'server': p['server'],
          'server_port': p['port'],
          if (p['username'] != null) 'username': p['username'],
          if (p['password'] != null) 'password': p['password'],
        };
      case 'http':
      case 'https':
        return {
          'type': 'http',
          'tag': tag,
          'server': p['server'],
          'server_port': p['port'],
          if (p['username'] != null) 'username': p['username'],
          if (p['password'] != null) 'password': p['password'],
          if (type.toLowerCase() == 'https') 'tls': {'enabled': true},
        };
      case 'ss':
      case 'shadowsocks':
        return {
          'type': 'shadowsocks',
          'tag': tag,
          'server': p['server'],
          'server_port': p['port'],
          'method': p['cipher'] ?? p['method'],
          'password': p['password'],
          if (p['plugin'] != null)
            'plugin': p['plugin'],
          if (p['plugin-opts'] != null)
            'plugin_opts': _stringifyPluginOpts(p['plugin-opts']),
        };
      case 'vmess':
        return _mapVmess(p, tag);
      case 'vless':
        return _mapVless(p, tag);
      case 'trojan':
        return _mapTrojan(p, tag);
      case 'hysteria2':
      case 'hy2':
        return _mapHysteria2(p, tag);
      default:
        return null;
    }
  }

  String? _stringifyPluginOpts(dynamic opts) {
    if (opts == null) return null;
    if (opts is String) return opts;
    if (opts is Map) {
      return opts.entries.map((e) => '${e.key}=${e.value}').join(';');
    }
    return '$opts';
  }

  Map<String, dynamic> _mapVmess(Map p, String tag) {
    final out = <String, dynamic>{
      'type': 'vmess',
      'tag': tag,
      'server': p['server'],
      'server_port': p['port'],
      'uuid': p['uuid'],
      'security': p['cipher'] ?? 'auto',
      'alter_id': p['alterId'] ?? p['alter-id'] ?? 0,
    };
    final tls = _tlsFromClash(p);
    if (tls != null) out['tls'] = tls;
    final transport = _transportFromClash(p);
    if (transport != null) out['transport'] = transport;
    return out;
  }

  Map<String, dynamic> _mapVless(Map p, String tag) {
    final out = <String, dynamic>{
      'type': 'vless',
      'tag': tag,
      'server': p['server'],
      'server_port': p['port'],
      'uuid': p['uuid'],
    };
    final flow = p['flow'];
    if (flow != null && '$flow'.isNotEmpty) {
      out['flow'] = '$flow';
    }
    final packetEncoding = p['packet-encoding'] ?? p['packet_encoding'];
    if (packetEncoding != null) {
      out['packet_encoding'] = packetEncoding;
    }
    final tls = _tlsFromClash(p);
    if (tls != null) out['tls'] = tls;
    final transport = _transportFromClash(p);
    if (transport != null) out['transport'] = transport;
    return out;
  }

  Map<String, dynamic> _mapTrojan(Map p, String tag) {
    final out = <String, dynamic>{
      'type': 'trojan',
      'tag': tag,
      'server': p['server'],
      'server_port': p['port'],
      'password': p['password'],
    };
    final tls = _tlsFromClash(p, defaultEnabled: true);
    if (tls != null) out['tls'] = tls;
    final transport = _transportFromClash(p);
    if (transport != null) out['transport'] = transport;
    return out;
  }

  Map<String, dynamic> _mapHysteria2(Map p, String tag) {
    final out = <String, dynamic>{
      'type': 'hysteria2',
      'tag': tag,
      'server': p['server'],
      'server_port': p['port'],
      if (p['password'] != null) 'password': p['password'],
      if (p['obfs'] != null || p['obfs-password'] != null)
        'obfs': {
          'type': p['obfs'] ?? 'salamander',
          if (p['obfs-password'] != null) 'password': p['obfs-password'],
        },
    };
    final tls = _tlsFromClash(p, defaultEnabled: true);
    if (tls != null) out['tls'] = tls;
    return out;
  }

  Map<String, dynamic>? _tlsFromClash(
    Map p, {
    bool defaultEnabled = false,
  }) {
    final tlsFlag = p['tls'] == true || p['tls'] == 'true';
    final reality = p['reality-opts'] ?? p['reality_opts'];
    final enabled = tlsFlag || reality != null || defaultEnabled;
    if (!enabled) return null;

    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': p['servername'] ?? p['sni'] ?? p['server'],
      'insecure': p['skip-cert-verify'] == true,
    };
    final alpn = p['alpn'];
    if (alpn is List) {
      tls['alpn'] = alpn.map((e) => '$e').toList();
    } else if (alpn is String && alpn.isNotEmpty) {
      tls['alpn'] = [alpn];
    }
    final fp = p['client-fingerprint'] ?? p['client_fingerprint'];
    if (fp != null && '$fp'.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': '$fp'};
    }
    if (reality is Map) {
      tls['reality'] = {
        'enabled': true,
        'public_key': reality['public-key'] ?? reality['public_key'],
        'short_id': reality['short-id'] ?? reality['short_id'] ?? '',
      };
    }
    return tls;
  }

  Map<String, dynamic>? _transportFromClash(Map p) {
    final network = '${p['network'] ?? p['net'] ?? 'tcp'}'.toLowerCase();
    if (network == 'ws' || network == 'websocket') {
      final opts = p['ws-opts'] ?? p['ws_opts'];
      final headers = <String, dynamic>{};
      if (opts is Map && opts['headers'] is Map) {
        for (final e in (opts['headers'] as Map).entries) {
          headers['${e.key}'] = '${e.value}';
        }
      }
      if (p['ws-headers'] is Map) {
        for (final e in (p['ws-headers'] as Map).entries) {
          headers['${e.key}'] = '${e.value}';
        }
      }
      return {
        'type': 'ws',
        'path': opts is Map
            ? (opts['path'] ?? p['ws-path'] ?? '/')
            : (p['ws-path'] ?? p['path'] ?? '/'),
        if (headers.isNotEmpty) 'headers': headers,
      };
    }
    if (network == 'grpc') {
      final opts = p['grpc-opts'] ?? p['grpc_opts'];
      return {
        'type': 'grpc',
        'service_name': opts is Map
            ? (opts['grpc-service-name'] ?? opts['service_name'] ?? '')
            : (p['grpc-service-name'] ?? ''),
      };
    }
    if (network == 'h2' || network == 'http') {
      final opts = p['h2-opts'] ?? p['http-opts'];
      return {
        'type': 'http',
        'path': opts is Map ? (opts['path'] ?? '/') : '/',
        if (opts is Map && opts['host'] != null)
          'host': opts['host'] is List
              ? (opts['host'] as List).map((e) => '$e').toList()
              : ['${opts['host']}'],
      };
    }
    return null;
  }

  /// Keep readable Clash names for Clash API / UI: flag emoji, CJK, latin.
  /// Only replace spaces and other punctuation with `_` (do not wipe 🇭🇰 / 自动选择).
  String _safeTag(String name) {
    final buf = StringBuffer();
    for (final rune in name.runes) {
      if (_isSafeTagRune(rune)) {
        buf.writeCharCode(rune);
      } else if (rune == 0x20 || rune == 0x09) {
        buf.write('_');
      } else {
        buf.write('_');
      }
    }
    var cleaned = buf.toString().replaceAll(RegExp(r'_+'), '_');
    cleaned = cleaned.replaceAll(RegExp(r'^_|_$'), '');
    if (cleaned.isEmpty) return 'node';
    // Allow longer tags so 「自动选择」+ flags are not truncated oddly.
    return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
  }

  bool _isSafeTagRune(int rune) {
    // ASCII alnum . _ -
    if ((rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        rune == 0x2E ||
        rune == 0x5F ||
        rune == 0x2D) {
      return true;
    }
    // Regional Indicator Symbols (flag pairs)
    if (rune >= 0x1F1E6 && rune <= 0x1F1FF) return true;
    // CJK Unified Ideographs (+ common extensions used in node titles)
    if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
    if (rune >= 0x3400 && rune <= 0x4DBF) return true;
    // Common emoji Presentation / Misc Symbols used in titles (non-flag)
    if (rune >= 0x2600 && rune <= 0x27BF) return true;
    if (rune >= 0x1F300 && rune <= 0x1FAFF) return true;
    return false;
  }
}

class _ConvertedDraft {
  _ConvertedDraft({
    required this.config,
    required this.proxyTotal,
    required this.mappedCount,
    required this.unmappedCount,
    required this.unmappedTypes,
  });

  final Map<String, dynamic> config;
  final int proxyTotal;
  final int mappedCount;
  final int unmappedCount;
  final Map<String, int> unmappedTypes;
}

class SubscriptionImportResult {
  const SubscriptionImportResult({
    required this.ok,
    required this.message,
    this.profileName,
    this.configPath,
    this.proxyCount,
    this.mappedCount,
    this.unmappedCount,
    this.unmappedTypes,
    this.userInfo,
  });

  final bool ok;
  final String message;
  final String? profileName;
  final String? configPath;
  final int? proxyCount;
  final int? mappedCount;
  final int? unmappedCount;
  final Map<String, int>? unmappedTypes;
  final SubscriptionUserInfo? userInfo;
}
