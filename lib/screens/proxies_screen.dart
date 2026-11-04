import 'package:flutter/material.dart';

import '../services/clash_api_client.dart';
import '../services/profile_proxy_loader.dart';
import '../services/profile_store.dart';
import '../utils/proxy_region_flag.dart';

/// Clash Verge–style proxy grid (Material 3).
///
/// Group/member lists follow the **selected subscription file**. Clash API is
/// only used to overlay live `now` / delay when it still matches that file.
class ProxiesScreen extends StatefulWidget {
  const ProxiesScreen({
    super.key,
    required this.clashApi,
    required this.profileStore,
    this.refreshToken = 0,
    this.activeProfileId,
  });

  final ClashApiClient clashApi;
  final ProfileStore profileStore;
  final int refreshToken;

  /// Primitive so [didUpdateWidget] sees subscription switches on a shared store.
  final String? activeProfileId;

  @override
  State<ProxiesScreen> createState() => _ProxiesScreenState();
}

class _ProxiesScreenState extends State<ProxiesScreen> {
  List<ClashProxyGroup> _groups = const [];
  Map<String, ClashProxyNode> _nodes = const {};
  bool _loading = true;
  bool _apiOk = false;
  bool _testing = false;
  String? _groupName;
  String? _selected;
  String _query = '';
  String? _hint;
  String? _profileLabel;
  String? _boundProfileId;
  final Map<String, int?> _delays = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant ProxiesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final activeChanged = oldWidget.activeProfileId != widget.activeProfileId;
    if (oldWidget.refreshToken != widget.refreshToken || activeChanged) {
      _reload();
    }
  }

  bool _isPlaceholder(List<ClashProxyGroup> groups) {
    if (groups.isEmpty) return true;
    if (groups.length != 1) return false;
    final n = groups.first.name;
    return n.contains('占位') || n.contains('不可用') || n.contains('无代理');
  }

  /// True when live API groups look like the selected subscription (not another).
  bool _apiMatchesFile(
    List<ClashProxyGroup> apiGroups,
    List<ClashProxyGroup> fileGroups,
  ) {
    if (apiGroups.isEmpty || fileGroups.isEmpty) return false;
    final fileByName = {for (final g in fileGroups) g.name: g};
    var matchedGroups = 0;
    var memberHits = 0;
    var memberTotal = 0;
    for (final g in apiGroups) {
      final file = fileByName[g.name];
      if (file == null) continue;
      matchedGroups++;
      final fileMembers = file.all.toSet();
      for (final m in g.all) {
        memberTotal++;
        if (fileMembers.contains(m)) memberHits++;
      }
    }
    if (matchedGroups == 0) return false;
    // At least half of file groups present, and most shared members overlap.
    if (matchedGroups < (fileGroups.length / 2).ceil()) return false;
    if (memberTotal == 0) return matchedGroups == fileGroups.length;
    return memberHits * 2 >= memberTotal;
  }

  List<ClashProxyGroup> _overlayLiveNow(
    List<ClashProxyGroup> fileGroups,
    List<ClashProxyGroup> apiGroups,
  ) {
    final apiByName = {for (final g in apiGroups) g.name: g};
    return fileGroups.map((g) {
      final live = apiByName[g.name];
      if (live == null) return g;
      final now = live.now;
      if (now.isEmpty || !g.all.contains(now)) return g;
      return ClashProxyGroup(
        name: g.name,
        type: g.type,
        now: now,
        all: g.all,
      );
    }).toList();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _hint = null;
    });

    await widget.profileStore.load();
    final active = widget.profileStore.activeProfile;
    final activeId = active?.id ?? widget.activeProfileId;
    final profileLabel = active?.name;

    // Reset group selection when subscription changes.
    if (activeId != _boundProfileId) {
      _groupName = null;
      _selected = null;
      _delays.clear();
      _boundProfileId = activeId;
    }

    final path = await widget.profileStore.activeConfigPath();
    final fromFile = path == null
        ? null
        : await ProfileProxyLoader.fromConfigPath(path);

    final catalog = await widget.clashApi.fetchProxyCatalog();
    final apiLive =
        catalog.reachable && !_isPlaceholder(catalog.groups);

    late final List<ClashProxyGroup> groups;
    late final Map<String, ClashProxyNode> nodes;
    var coreFollowsSelection = false;
    var previewOnly = false;

    if (fromFile != null && !_isPlaceholder(fromFile.groups)) {
      // Selected subscription file is the source of truth for membership.
      nodes = Map<String, ClashProxyNode>.from(fromFile.nodes);
      if (apiLive && _apiMatchesFile(catalog.groups, fromFile.groups)) {
        groups = _overlayLiveNow(fromFile.groups, catalog.groups);
        coreFollowsSelection = true;
        for (final e in catalog.nodes.entries) {
          final existing = nodes[e.key];
          if (existing == null) continue;
          if (e.value.delayMs != null) {
            nodes[e.key] = ClashProxyNode(
              name: e.key,
              type: existing.type,
              delayMs: e.value.delayMs,
            );
          }
        }
      } else {
        groups = fromFile.groups;
        previewOnly = true;
      }
    } else if (apiLive) {
      // No usable local file — last resort: show whatever the core has.
      groups = catalog.groups;
      nodes = catalog.nodes;
      coreFollowsSelection = true;
    } else {
      groups = const [];
      nodes = const {};
    }

    final realGroups = _isPlaceholder(groups) ? const <ClashProxyGroup>[] : groups;

    ClashProxyGroup? preferredDefault() {
      if (realGroups.isEmpty) return null;
      for (final g in realGroups) {
        if (g.type == 'Selector' && g.name.toUpperCase() != 'GLOBAL') {
          return g;
        }
      }
      return realGroups.first;
    }

    ClashProxyGroup? activeGroup;
    if (realGroups.isNotEmpty) {
      for (final g in realGroups) {
        if (g.name == _groupName) {
          activeGroup = g;
          break;
        }
      }
      activeGroup ??= preferredDefault();
    }

    if (!mounted) return;
    setState(() {
      _groups = realGroups;
      _nodes = nodes;
      _apiOk = realGroups.isNotEmpty;
      _groupName = activeGroup?.name;
      _selected = activeGroup?.now;
      _profileLabel = profileLabel;
      _loading = false;
      for (final e in nodes.entries) {
        if (e.value.delayMs != null) {
          _delays[e.key] = e.value.delayMs;
        }
      }
      if (active == null) {
        _hint = '请先在「订阅」选择一个配置。';
      } else if (realGroups.isEmpty) {
        _hint = '「${active.name}」暂无节点，请同步或重新导入。';
      } else if (previewOnly && apiLive) {
        _hint = '显示「${active.name}」；内核仍是其他订阅，请回「订阅」再点选用或开连接。';
      } else if (previewOnly) {
        _hint = '显示「${active.name}」配置（内核未连接时为本地预览）。';
      } else if (!coreFollowsSelection) {
        _hint = '显示「${active.name}」配置（内核未连接时为本地预览）。';
      } else {
        _hint = null;
      }
    });
  }

  ClashProxyGroup? get _activeGroup {
    if (_groups.isEmpty) return null;
    return _groups.firstWhere(
      (g) => g.name == _groupName,
      orElse: () => _groups.first,
    );
  }

  List<String> get _visibleNames {
    final g = _activeGroup;
    if (g == null) return const [];
    final q = _query.trim().toLowerCase();
    return g.all.where((n) {
      if (q.isEmpty) return true;
      final type = (_nodes[n]?.type ?? '').toLowerCase();
      return n.toLowerCase().contains(q) || type.contains(q);
    }).toList();
  }

  Future<void> _select(String name) async {
    final g = _activeGroup;
    if (g == null) return;
    try {
      await widget.clashApi.selectProxy(group: g.name, name: name);
      if (!mounted) return;
      setState(() => _selected = name);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('切换失败（Clash API 不可用）')),
      );
    }
  }

  Future<void> _testVisible() async {
    final names = _visibleNames;
    if (names.isEmpty) return;
    setState(() => _testing = true);
    try {
      for (final name in names) {
        final ms = await widget.clashApi.testDelay(name: name);
        if (!mounted) return;
        setState(() => _delays[name] = ms);
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _showSearch() async {
    final controller = TextEditingController(text: _query);
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('搜索节点'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '名称 / 类型',
              prefixIcon: Icon(Icons.search),
            ),
            onSubmitted: (v) {
              setState(() => _query = v);
              Navigator.pop(ctx);
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() => _query = '');
                Navigator.pop(ctx);
              },
              child: const Text('清除'),
            ),
            FilledButton(
              onPressed: () {
                setState(() => _query = controller.text);
                Navigator.pop(ctx);
              },
              child: const Text('搜索'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final names = _visibleNames;
    final selected = _selected ?? _activeGroup?.now;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '代理',
                      style:
                          Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                    ),
                    if (_profileLabel != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        '订阅：$_profileLabel',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: '搜索',
                onPressed: _showSearch,
                icon: Badge(
                  isLabelVisible: _query.isNotEmpty,
                  child: const Icon(Icons.search),
                ),
              ),
              IconButton(
                tooltip: '测速',
                onPressed: _testing || names.isEmpty ? null : _testVisible,
                icon: _testing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bolt),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (v) {
                  if (v == 'refresh') _reload();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'refresh', child: Text('刷新列表')),
                ],
              ),
            ],
          ),
        ),
        if (_groups.isNotEmpty)
          SizedBox(
            height: 40,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              itemCount: _groups.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final g = _groups[i];
                final selectedGroup =
                    g.name == (_groupName ?? _groups.first.name);
                final label = ProxyRegionFlag.displayName(g.name, type: g.type);
                return FilterChip(
                  selected: selectedGroup,
                  label: Text(label),
                  onSelected: (_) {
                    setState(() {
                      _groupName = g.name;
                      _selected = g.now;
                    });
                  },
                );
              },
            ),
          ),
        if (_hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              _hint!,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        Expanded(
          child: names.isEmpty
              ? Center(
                  child: Text(
                    _apiOk ? '无匹配节点' : '暂无节点',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 168,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.35,
                  ),
                  itemCount: names.length,
                  itemBuilder: (context, i) {
                    final name = names[i];
                    final node = _nodes[name];
                    final type = node?.type ??
                        (name == 'DIRECT' || name == 'direct'
                            ? 'Direct'
                            : name == 'REJECT' || name == 'block'
                                ? 'Reject'
                                : '—');
                    final delay = _delays[name] ?? node?.delayMs;
                    final isSelected = name == selected;
                    return _ProxyCard(
                      name: name,
                      type: type,
                      delayMs: delay,
                      selected: isSelected,
                      onTap: () => _select(name),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ProxyCard extends StatelessWidget {
  const _ProxyCard({
    required this.name,
    required this.type,
    required this.delayMs,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final String type;
  final int? delayMs;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final flag = ProxyRegionFlag.flagFor(name);
    final title = ProxyRegionFlag.displayName(name, type: type);
    final delayText = delayMs == null
        ? ''
        : (delayMs! < 0 ? '超时' : '${delayMs}ms');
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.4 : 0.8,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (flag != null) ...[
                    Text(flag, style: const TextStyle(fontSize: 20, height: 1.1)),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      type,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  if (delayText.isNotEmpty)
                    Text(
                      delayText,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: delayMs != null && delayMs! >= 0
                                ? scheme.primary
                                : scheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
