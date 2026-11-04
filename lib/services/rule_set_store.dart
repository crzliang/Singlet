import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'route_defaults.dart';

/// Downloads / caches remote sing-box rule-sets under Application Support.
class RuleSetStore {
  RuleSetStore({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const metaFileName = 'rule-sets.meta.json';

  Future<Directory> ruleSetsDir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/rule-sets');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> cacheDbPath() async {
    final root = await getApplicationSupportDirectory();
    return '${root.path}/cache.db';
  }

  Future<String?> localPathFor(String tag) async {
    final dir = await ruleSetsDir();
    final file = File('${dir.path}/$tag.srs');
    if (await file.exists() && await file.length() > 0) {
      return file.path;
    }
    return null;
  }

  /// tag → absolute path for rule-sets that are already downloaded.
  Future<Map<String, String>> localPathsFor(BypassRouteSettings route) async {
    final out = <String, String>{};
    for (final item in pendingDownloads(route)) {
      final path = await localPathFor(item.tag);
      if (path != null) out[item.tag] = path;
    }
    return out;
  }

  Future<DateTime?> lastUpdatedAt() async {
    try {
      final dir = await ruleSetsDir();
      final meta = File('${dir.path}/$metaFileName');
      if (await meta.exists()) {
        final decoded = jsonDecode(await meta.readAsString());
        if (decoded is Map && decoded['updatedAt'] != null) {
          return DateTime.tryParse('${decoded['updatedAt']}');
        }
      }
      // Fallback: newest .srs mtime.
      DateTime? newest;
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.srs')) continue;
        final m = (await entity.stat()).modified;
        if (newest == null || m.isAfter(newest)) newest = m;
      }
      return newest;
    } catch (_) {
      return null;
    }
  }

  /// Remote rule-sets needed for current [route] settings.
  List<({String tag, String url, String label})> pendingDownloads(
    BypassRouteSettings route,
  ) {
    if (!route.enabled) return const [];
    final out = <({String tag, String url, String label})>[];
    if (route.privateDirect) {
      out.add((
        tag: RouteDefaults.geoipPrivateTag,
        url: RouteDefaults.geoipPrivateUrl,
        label: 'geoip-private',
      ));
    }
    if (route.chinaDirect) {
      out.add((
        tag: RouteDefaults.geositeCnTag,
        url: RouteDefaults.geositeCnUrl,
        label: 'geosite-cn',
      ));
      out.add((
        tag: RouteDefaults.geoipCnTag,
        url: RouteDefaults.geoipCnUrl,
        label: 'geoip-cn',
      ));
    }
    if (route.blockAds) {
      out.add((
        tag: RouteDefaults.geositeAdsTag,
        url: RouteDefaults.geositeAdsUrl,
        label: 'ads',
      ));
    }
    return out;
  }

  /// Download enabled rule-sets. Returns count of files written.
  Future<RuleSetUpdateResult> updateEnabled(BypassRouteSettings route) async {
    final items = pendingDownloads(route);
    if (items.isEmpty) {
      return const RuleSetUpdateResult(
        ok: true,
        downloaded: 0,
        message: '当前未启用需要下载的规则集',
      );
    }
    final dir = await ruleSetsDir();
    final errors = <String>[];
    var okCount = 0;
    for (final item in items) {
      try {
        final res = await _client
            .get(Uri.parse(item.url))
            .timeout(const Duration(seconds: 60));
        if (res.statusCode != 200) {
          errors.add('${item.label}: HTTP ${res.statusCode}');
          continue;
        }
        if (res.bodyBytes.isEmpty) {
          errors.add('${item.label}: 空文件');
          continue;
        }
        final file = File('${dir.path}/${item.tag}.srs');
        await file.writeAsBytes(res.bodyBytes, flush: true);
        // World-readable so Privileged Helper (root) can load local rule-sets.
        try {
          await Process.run('chmod', ['644', file.path]);
        } catch (_) {}
        okCount++;
      } catch (e) {
        errors.add('${item.label}: $e');
      }
    }

    final now = DateTime.now().toUtc();
    await File('${dir.path}/$metaFileName').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'updatedAt': now.toIso8601String(),
        'files': [
          for (final item in items) item.tag,
        ],
      }),
    );

    // Drop sing-box remote cache so next start prefers fresh local/remote.
    try {
      final cache = File(await cacheDbPath());
      if (await cache.exists()) await cache.delete();
    } catch (_) {}

    if (okCount == 0) {
      return RuleSetUpdateResult(
        ok: false,
        downloaded: 0,
        message: errors.isEmpty ? '下载失败' : errors.join('；'),
      );
    }
    if (errors.isNotEmpty) {
      return RuleSetUpdateResult(
        ok: true,
        downloaded: okCount,
        message: '已更新 $okCount/${items.length}：${errors.join('；')}',
      );
    }
    return RuleSetUpdateResult(
      ok: true,
      downloaded: okCount,
      message: '已更新 $okCount 个规则集',
      updatedAt: now.toLocal(),
    );
  }
}

class RuleSetUpdateResult {
  const RuleSetUpdateResult({
    required this.ok,
    required this.downloaded,
    required this.message,
    this.updatedAt,
  });

  final bool ok;
  final int downloaded;
  final String message;
  final DateTime? updatedAt;
}

/// Apply [RouteDefaults] with on-disk `.srs` paths + cache.db location.
Future<void> applyRouteDefaultsWithLocals(
  Map<String, dynamic> config, {
  required String proxyOutbound,
  required BypassRouteSettings route,
  RuleSetStore? store,
}) async {
  final ruleSets = store ?? RuleSetStore();
  RouteDefaults.applyToConfig(
    config,
    proxyOutbound: proxyOutbound,
    route: route,
    localRuleSetPaths: await ruleSets.localPathsFor(route),
    cacheFilePath: await ruleSets.cacheDbPath(),
  );
}
