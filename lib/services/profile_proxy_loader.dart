import 'dart:convert';
import 'dart:io';

import 'clash_api_client.dart';

/// Build a proxy catalog from a sing-box JSON config (active subscription file).
///
/// Used so the 节点 page can follow the selected profile even when Clash API
/// is down or still catching up after a config switch.
class ProfileProxyLoader {
  ProfileProxyLoader._();

  static Future<ClashProxyCatalog?> fromConfigPath(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return fromConfigMap(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static ClashProxyCatalog? fromConfigMap(Map<String, dynamic> config) {
    final outbounds = config['outbounds'];
    if (outbounds is! List) return null;

    final nodes = <String, ClashProxyNode>{};
    final groups = <ClashProxyGroup>[];
    final leafTags = <String>[];

    for (final item in outbounds) {
      if (item is! Map) continue;
      final type = '${item['type'] ?? ''}';
      final tag = '${item['tag'] ?? ''}';
      if (tag.isEmpty) continue;

      if (type == 'selector' || type == 'urltest') {
        final members = <String>[];
        final list = item['outbounds'];
        if (list is List) {
          for (final m in list) {
            members.add('$m');
          }
        }
        final now = type == 'selector'
            ? '${item['default'] ?? (members.isNotEmpty ? members.first : '')}'
            : (members.isNotEmpty ? members.first : '');
        groups.add(
          ClashProxyGroup(
            name: tag,
            type: type == 'urltest' ? 'URLTest' : 'Selector',
            now: now,
            all: members,
          ),
        );
        nodes[tag] = ClashProxyNode(name: tag, type: type);
      } else if (type == 'direct' || type == 'block' || type == 'dns') {
        nodes[tag] = ClashProxyNode(
          name: tag,
          type: type == 'direct'
              ? 'Direct'
              : (type == 'block' ? 'Reject' : type),
        );
      } else {
        leafTags.add(tag);
        nodes[tag] = ClashProxyNode(name: tag, type: type);
      }
    }

    if (groups.isEmpty && leafTags.isNotEmpty) {
      groups.add(
        ClashProxyGroup(
          name: 'proxy',
          type: 'Selector',
          now: leafTags.first,
          all: [...leafTags, if (nodes.containsKey('direct')) 'direct'],
        ),
      );
    }

    if (groups.isEmpty) return null;

    // Prefer selector groups that look like 节点选择 ahead of GLOBAL-like tags.
    groups.sort((a, b) {
      int rank(ClashProxyGroup g) {
        final n = g.name.toUpperCase();
        if (g.type == 'Selector' && n != 'GLOBAL') return 0;
        if (g.type == 'URLTest') return 1;
        if (n == 'GLOBAL') return 3;
        return 2;
      }

      return rank(a).compareTo(rank(b));
    });

    return ClashProxyCatalog(
      groups: groups,
      nodes: nodes,
      reachable: true,
    );
  }
}
