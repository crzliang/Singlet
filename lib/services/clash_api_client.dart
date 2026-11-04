import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Clash Meta / sing-box Clash API HTTP client.
class ClashApiClient {
  ClashApiClient({this.baseUrl = 'http://127.0.0.1:9090', http.Client? client})
      : _client = client ?? http.Client();

  String baseUrl;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    return base.replace(
      path: _join(base.path, path),
      queryParameters: query,
    );
  }

  /// True when Clash API answers (used to decide whether core is really up).
  Future<bool> isReachable() async {
    try {
      final res = await _client
          .get(_uri('/version'))
          .timeout(const Duration(seconds: 1));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  String _join(String a, String b) {
    if (a.endsWith('/')) a = a.substring(0, a.length - 1);
    if (!b.startsWith('/')) b = '/$b';
    return '$a$b';
  }

  Future<List<ClashProxyGroup>> fetchProxyGroups() async {
    final catalog = await fetchProxyCatalog();
    return catalog.groups;
  }

  /// Full /proxies snapshot: groups + per-node type/history delay.
  Future<ClashProxyCatalog> fetchProxyCatalog() async {
    try {
      final res = await _client.get(_uri('/proxies')).timeout(
            const Duration(seconds: 3),
          );
      if (res.statusCode != 200) {
        debugPrint('clash /proxies HTTP ${res.statusCode}');
        return ClashProxyCatalog(groups: _placeholder(), nodes: const {});
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final proxies = body['proxies'] as Map<String, dynamic>? ?? {};
      final groups = <ClashProxyGroup>[];
      final nodes = <String, ClashProxyNode>{};
      for (final entry in proxies.entries) {
        final m = entry.value as Map<String, dynamic>;
        final type = (m['type'] as String?) ?? '';
        final history = m['history'] as List? ?? const [];
        int? lastDelay;
        if (history.isNotEmpty) {
          final last = history.last;
          if (last is Map && last['delay'] != null) {
            lastDelay = _asInt(last['delay']);
            if (lastDelay == 0) lastDelay = null;
          }
        }
        nodes[entry.key] = ClashProxyNode(
          name: entry.key,
          type: type,
          delayMs: lastDelay,
        );
        final all =
            (m['all'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
        if (all.isEmpty) continue;
        if (type == 'Selector' ||
            type == 'URLTest' ||
            type == 'Fallback' ||
            type == 'LoadBalance') {
          groups.add(
            ClashProxyGroup(
              name: entry.key,
              type: type,
              now: (m['now'] as String?) ?? (all.isNotEmpty ? all.first : ''),
              all: all,
            ),
          );
        }
      }
      if (groups.isEmpty) {
        return ClashProxyCatalog(
          groups: _placeholder(message: '无代理组'),
          nodes: nodes,
        );
      }
      // Clash Verge–like: prefer Selector tabs; keep GLOBAL last.
      groups.sort((a, b) {
        int rank(ClashProxyGroup g) {
          final n = g.name.toUpperCase();
          if (n == 'GLOBAL') return 50;
          switch (g.type) {
            case 'Selector':
              return 0;
            case 'URLTest':
              return 1;
            case 'Fallback':
              return 2;
            case 'LoadBalance':
              return 3;
            default:
              return 10;
          }
        }

        final d = rank(a) - rank(b);
        if (d != 0) return d;
        return a.name.compareTo(b.name);
      });
      return ClashProxyCatalog(groups: groups, nodes: nodes, reachable: true);
    } catch (e) {
      final msg = '$e';
      // Connection refused while core is starting is expected — don't spam.
      if (!msg.contains('Connection refused') &&
          !msg.contains('connection abort')) {
        debugPrint('clash fetchProxyCatalog: $e');
      }
      return ClashProxyCatalog(
        groups: _placeholder(message: 'Clash API 不可用'),
        nodes: const {},
      );
    }
  }

  List<ClashProxyGroup> _placeholder({String message = '占位'}) => [
        // Name markers consumed by ProxiesScreen empty-state detection.
        ClashProxyGroup(
          name: message.contains('占位') ? message : '占位 · $message',
          type: 'Selector',
          now: 'DIRECT',
          all: const ['DIRECT'],
        ),
      ];

  Future<void> selectProxy({
    required String group,
    required String name,
  }) async {
    final res = await _client.put(
      _uri('/proxies/${Uri.encodeComponent(group)}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name}),
    );
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw Exception('select failed HTTP ${res.statusCode}: ${res.body}');
    }
  }

  /// Clash uses DIRECT/REJECT; sing-box tags are usually direct/block.
  static String normalizeProxyName(String name) {
    switch (name) {
      case 'DIRECT':
        return 'direct';
      case 'REJECT':
        return 'block';
      default:
        return name;
    }
  }

  Future<int?> testDelay({
    required String name,
    String url = 'https://www.gstatic.com/generate_204',
    int timeoutMs = 5000,
  }) async {
    final probe = normalizeProxyName(name);
    try {
      final res = await _client
          .get(
            _uri('/proxies/${Uri.encodeComponent(probe)}/delay', {
              'url': url,
              'timeout': '$timeoutMs',
            }),
          )
          .timeout(Duration(milliseconds: timeoutMs + 1000));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final delay = body['delay'];
      if (delay is int) return delay;
      if (delay is num) return delay.toInt();
      return null;
    } catch (e) {
      debugPrint('clash delay: $e');
      return null;
    }
  }

  /// GET /configs — mode is typically rule | global | direct.
  Future<ClashConfigs> fetchConfigs() async {
    try {
      final res = await _client
          .get(_uri('/configs'))
          .timeout(const Duration(seconds: 2));
      if (res.statusCode != 200) return const ClashConfigs();
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return ClashConfigs(
        mode: (body['mode'] as String?) ?? 'rule',
        reachable: true,
      );
    } catch (_) {
      return const ClashConfigs();
    }
  }

  Future<bool> setMode(String mode) async {
    try {
      final res = await _client
          .patch(
            _uri('/configs'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'mode': mode}),
          )
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 204 || res.statusCode == 200;
    } catch (e) {
      debugPrint('clash setMode: $e');
      return false;
    }
  }

  /// Seen connection ids since process start (for「最近请求」累计).
  final Set<String> _seenConnectionIds = {};

  /// Prior totals for per-connection speed (id → upload/download + timestamp).
  final Map<String, (int up, int down, DateTime at)> _connTrafficPrev = {};

  void resetConnectionTotals() {
    _seenConnectionIds.clear();
    _connTrafficPrev.clear();
  }

  /// Snapshot from GET /connections (active + cumulative + dns estimate).
  Future<ClashConnectionsSnapshot> fetchConnections() async {
    final detail = await fetchConnectionList();
    return ClashConnectionsSnapshot(
      count: detail.rows.length,
      uploadTotal: detail.uploadTotal,
      downloadTotal: detail.downloadTotal,
      reachable: detail.reachable,
      totalSeen: _seenConnectionIds.length,
      dnsActive: detail.rows.where((r) => r.isDns).length,
    );
  }

  /// Full connection rows for the「实时连接」page.
  Future<ClashConnectionList> fetchConnectionList() async {
    try {
      final res = await _client
          .get(_uri('/connections'))
          .timeout(const Duration(seconds: 2));
      if (res.statusCode != 200) {
        return const ClashConnectionList();
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final list = body['connections'] as List? ?? const [];
      final now = DateTime.now();
      final rows = <ClashConnectionRow>[];
      final liveIds = <String>{};

      for (final item in list) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final id = '${m['id'] ?? ''}';
        if (id.isEmpty) continue;
        liveIds.add(id);
        _seenConnectionIds.add(id);

        final metaRaw = m['metadata'];
        final meta = metaRaw is Map
            ? Map<String, dynamic>.from(metaRaw)
            : <String, dynamic>{};

        final upload = _asInt(m['upload']);
        final download = _asInt(m['download']);
        var upSpeed = _asInt(m['uploadSpeed'] ?? m['upSpeed']);
        var downSpeed = _asInt(m['downloadSpeed'] ?? m['downSpeed']);
        final prev = _connTrafficPrev[id];
        if ((upSpeed == 0 && downSpeed == 0) && prev != null) {
          final dt = now.difference(prev.$3).inMilliseconds / 1000.0;
          if (dt > 0.05) {
            upSpeed = ((upload - prev.$1) / dt).round().clamp(0, 1 << 62);
            downSpeed = ((download - prev.$2) / dt).round().clamp(0, 1 << 62);
          }
        }
        _connTrafficPrev[id] = (upload, download, now);

        final host = '${meta['host'] ?? ''}'.trim();
        final destIp = '${meta['destinationIP'] ?? ''}'.trim();
        final destPort =
            '${meta['destinationPort'] ?? meta['dstPort'] ?? ''}'.trim();
        final targetHost =
            host.isNotEmpty ? host : (destIp.isNotEmpty ? destIp : '—');
        final target =
            destPort.isEmpty ? targetHost : '$targetHost:$destPort';

        final process = '${meta['process'] ?? ''}'.trim();
        final processPath = '${meta['processPath'] ?? ''}'.trim();
        final processLabel = process.isNotEmpty
            ? process
            : (processPath.isNotEmpty
                ? processPath.split('/').last
                : '—');

        final chains = (m['chains'] as List?)?.map((e) => '$e').toList() ??
            const <String>[];
        final outbound = chains.isNotEmpty ? chains.first : '—';

        rows.add(
          ClashConnectionRow(
            id: id,
            process: processLabel,
            target: target,
            rule: '${m['rule'] ?? '—'}',
            outbound: outbound,
            upload: upload,
            download: download,
            uploadSpeed: upSpeed,
            downloadSpeed: downSpeed,
            network: '${meta['network'] ?? ''}',
            isDns: _looksLikeDns(m),
          ),
        );
      }

      _connTrafficPrev.removeWhere((id, _) => !liveIds.contains(id));

      return ClashConnectionList(
        rows: rows,
        uploadTotal: _asInt(body['uploadTotal']),
        downloadTotal: _asInt(body['downloadTotal']),
        reachable: true,
      );
    } catch (_) {
      return const ClashConnectionList();
    }
  }

  Future<bool> closeConnection(String id) async {
    try {
      final res = await _client
          .delete(_uri('/connections/$id'))
          .timeout(const Duration(seconds: 2));
      return res.statusCode == 200 || res.statusCode == 204;
    } catch (e) {
      debugPrint('clash closeConnection: $e');
      return false;
    }
  }

  Future<bool> closeAllConnections() async {
    try {
      final res = await _client
          .delete(_uri('/connections'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200 || res.statusCode == 204;
    } catch (e) {
      debugPrint('clash closeAllConnections: $e');
      return false;
    }
  }

  static bool _looksLikeDns(Map item) {
    final meta = item['metadata'];
    if (meta is! Map) return false;
    final m = Map<String, dynamic>.from(meta);
    final host = '${m['host'] ?? ''}'.toLowerCase();
    final destPort = '${m['destinationPort'] ?? m['dstPort'] ?? ''}';
    final network = '${m['network'] ?? ''}'.toLowerCase();
    final type = '${m['type'] ?? ''}'.toLowerCase();
    if (destPort == '53') return true;
    if (type.contains('dns')) return true;
    if (network == 'udp' &&
        (host.contains('dns') || host.endsWith('.arpa'))) {
      return true;
    }
    return false;
  }

  /// Read one SSE frame from GET /traffic (up/down bytes per second).
  Future<ClashTrafficSample> peekTraffic() async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 2);
      final req = await client.getUrl(_uri('/traffic'));
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      final res = await req.close().timeout(const Duration(seconds: 2));
      if (res.statusCode != 200) {
        return const ClashTrafficSample();
      }
      await for (final chunk in res.transform(utf8.decoder).timeout(
            const Duration(seconds: 2),
          )) {
        for (final line in chunk.split('\n')) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('{')) continue;
          final map = jsonDecode(trimmed) as Map<String, dynamic>;
          return ClashTrafficSample(
            up: _asInt(map['up']),
            down: _asInt(map['down']),
            reachable: true,
          );
        }
      }
      return const ClashTrafficSample();
    } catch (_) {
      return const ClashTrafficSample();
    } finally {
      client?.close(force: true);
    }
  }

  /// Optional GET /memory (Clash Meta); sing-box may 404 → placeholder.
  Future<ClashMemory?> fetchMemory() async {
    try {
      final res = await _client
          .get(_uri('/memory'))
          .timeout(const Duration(seconds: 2));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return ClashMemory(
        inuse: _asInt(body['inuse'] ?? body['inUse']),
        oslimit: _asInt(body['oslimit'] ?? body['osLimit']),
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> fetchVersion() async {
    try {
      final res = await _client
          .get(_uri('/version'))
          .timeout(const Duration(seconds: 2));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['version']?.toString();
    } catch (_) {
      return null;
    }
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }
}

class ClashProxyGroup {
  const ClashProxyGroup({
    required this.name,
    required this.type,
    required this.now,
    required this.all,
  });

  final String name;
  final String type;
  final String now;
  final List<String> all;
}

class ClashProxyNode {
  const ClashProxyNode({
    required this.name,
    required this.type,
    this.delayMs,
  });

  final String name;
  final String type;
  final int? delayMs;
}

class ClashProxyCatalog {
  const ClashProxyCatalog({
    required this.groups,
    required this.nodes,
    this.reachable = false,
  });

  final List<ClashProxyGroup> groups;
  final Map<String, ClashProxyNode> nodes;
  final bool reachable;
}

class ClashConfigs {
  const ClashConfigs({this.mode = 'rule', this.reachable = false});
  final String mode;
  final bool reachable;
}

class ClashConnectionsSnapshot {
  const ClashConnectionsSnapshot({
    this.count = 0,
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.reachable = false,
    this.totalSeen = 0,
    this.dnsActive = 0,
  });
  final int count;
  final int uploadTotal;
  final int downloadTotal;
  final bool reachable;

  /// Distinct connection ids observed since app start.
  final int totalSeen;

  /// Active connections that look like DNS (port 53 / dns type).
  final int dnsActive;
}

class ClashConnectionList {
  const ClashConnectionList({
    this.rows = const [],
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.reachable = false,
  });

  final List<ClashConnectionRow> rows;
  final int uploadTotal;
  final int downloadTotal;
  final bool reachable;
}

class ClashConnectionRow {
  const ClashConnectionRow({
    required this.id,
    required this.process,
    required this.target,
    required this.rule,
    required this.outbound,
    required this.upload,
    required this.download,
    required this.uploadSpeed,
    required this.downloadSpeed,
    required this.network,
    required this.isDns,
  });

  final String id;
  final String process;
  final String target;
  final String rule;
  final String outbound;
  final int upload;
  final int download;
  final int uploadSpeed;
  final int downloadSpeed;
  final String network;
  final bool isDns;
}

class ClashTrafficSample {
  const ClashTrafficSample({
    this.up = 0,
    this.down = 0,
    this.reachable = false,
  });
  final int up;
  final int down;
  final bool reachable;
}

class ClashMemory {
  const ClashMemory({required this.inuse, required this.oslimit});
  final int inuse;
  final int oslimit;
}

/// Format bytes for UI.
String formatBytes(int n, {int fractionDigits = 1}) {
  if (n < 1024) return '$n B';
  final kb = n / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(fractionDigits)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(fractionDigits)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(fractionDigits)} GB';
}

String formatSpeed(int bytesPerSec) => '${formatBytes(bytesPerSec)}/s';
