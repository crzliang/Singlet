import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/subscription_profile.dart';
import '../services/helper_channel.dart';
import '../services/profile_store.dart';
import '../services/singbox_core_channel.dart';
import '../services/subscription_service.dart';
import '../services/system_proxy_channel.dart';
import '../services/tun_config.dart';
import '../utils/profile_format.dart';

/// Clash Verge–style「配置」page: profile card grid + edit side panel.
class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({
    super.key,
    required this.subscriptions,
    required this.profiles,
    required this.core,
    required this.helper,
    this.onApplied,
  });

  final SubscriptionService subscriptions;
  final ProfileStore profiles;
  final SingboxCoreChannel core;
  final HelperChannel helper;
  final VoidCallback? onApplied;

  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _editingId;
  String _sort = 'updated'; // updated | name

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await widget.profiles.load();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  List<SubscriptionProfile> _sortedOf(Iterable<SubscriptionProfile> source) {
    final list = [...source];
    switch (_sort) {
      case 'name':
        list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      default:
        list.sort((a, b) {
          final at = a.updatedAt?.millisecondsSinceEpoch ?? 0;
          final bt = b.updatedAt?.millisecondsSinceEpoch ?? 0;
          return bt.compareTo(at);
        });
    }
    return list;
  }

  List<SubscriptionProfile> get _remoteProfiles =>
      _sortedOf(widget.profiles.profiles.where((p) => p.isRemote));

  List<SubscriptionProfile> get _localProfiles =>
      _sortedOf(widget.profiles.profiles.where((p) => p.isLocal));

  SubscriptionProfile? get _editing {
    final id = _editingId;
    if (id == null) return null;
    for (final p in widget.profiles.profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> _snack(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _sync(
    SubscriptionProfile profile, {
    bool apply = false,
    bool manageBusy = true,
    bool quiet = false,
  }) async {
    if (profile.isLocal || profile.url.trim().isEmpty) {
      if (!quiet) await _snack('本地订阅无需同步');
      return;
    }
    if (manageBusy) setState(() => _busy = true);
    try {
      final result = await widget.subscriptions.importFromUrl(
        profile.url,
        configFileName: profile.resolvedConfigFileName,
        profileName: profile.name,
      );
      if (!result.ok || result.configPath == null) {
        if (!quiet) await _snack(result.message);
        return;
      }
      final info = result.userInfo;
      final updated = SubscriptionProfile(
        id: profile.id,
        name: profile.name,
        url: profile.url,
        autoUpdate: profile.autoUpdate,
        autoUpdateIntervalMin: profile.autoUpdateIntervalMin,
        updatedAt: DateTime.now(),
        expireAt: info?.expireAt ?? profile.expireAt,
        upload: info?.upload ?? profile.upload,
        download: info?.download ?? profile.download,
        total: info?.total ?? profile.total,
        configFileName: profile.resolvedConfigFileName,
        mappedCount: result.mappedCount ?? profile.mappedCount,
        proxyTotal: result.proxyCount ?? profile.proxyTotal,
      );
      await widget.profiles.update(updated);
      if (mounted) setState(() {});

      final shouldApply = apply || widget.profiles.activeId == profile.id;
      if (shouldApply) {
        await widget.profiles.setActive(profile.id);
        try {
          await _applyRunningCore(result.configPath!);
          widget.onApplied?.call();
          if (!quiet) await _snack('已同步并应用');
        } catch (e) {
          widget.onApplied?.call();
          if (!quiet) await _snack('已同步，内核切换失败: $e');
        }
      } else if (!quiet) {
        await _snack(result.message);
      }
    } finally {
      if (manageBusy && mounted) setState(() => _busy = false);
    }
  }

  /// Apply [path] to in-app core and/or Helper TUN so 节点页跟随该订阅.
  Future<void> _applyRunningCore(String path) async {
    TunHelperStatus tun = const TunHelperStatus(reachable: false);
    try {
      tun = await widget.helper.tunStatus();
    } catch (_) {}

    if (tun.reachable && tun.running) {
      final tunPath = await TunConfig.writeTunVariant(path);
      final port = await TunConfig.mixedPortFromConfig(path);
      await widget.helper.tunStop();
      await widget.helper.tunStart(
        configPath: tunPath,
        clashApiBaseUrl: 'http://127.0.0.1:9090',
        httpPort: port,
        apiPort: 9090,
      );
      try {
        await SystemProxyChannel().enableTunDns(
          servers: TunConfig.tunDnsServers,
        );
      } catch (_) {}
      return;
    }

    if (await widget.core.isRunning()) {
      await widget.core.applyConfig(path);
      return;
    }
    // Core stopped: still mark applied so 节点页读本地配置预览。
  }

  Future<void> _select(SubscriptionProfile profile) async {
    setState(() => _busy = true);
    try {
      await widget.profiles.setActive(profile.id);
      setState(() {});
      final path = await widget.profiles.activeConfigPath();
      final hasOwnFile = path != null &&
          path.endsWith(profile.resolvedConfigFileName);
      if (!hasOwnFile && profile.url.isNotEmpty) {
        await _sync(profile, apply: true);
        return;
      }
      if (path == null) {
        await _snack('尚无本地配置，请先同步');
        widget.onApplied?.call();
        return;
      }
      try {
        await _applyRunningCore(path);
        widget.onApplied?.call();
        await _snack('已选用「${profile.name}」');
      } catch (e) {
        if (profile.url.isNotEmpty) {
          await _sync(profile, apply: true);
        } else {
          widget.onApplied?.call();
          await _snack('选用失败: $e');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshAll() async {
    final list =
        widget.profiles.profiles.where((p) => p.isRemote && p.url.isNotEmpty).toList();
    if (list.isEmpty) {
      await _snack('没有可刷新的远程订阅');
      return;
    }
    setState(() => _busy = true);
    try {
      for (final p in list) {
        await _sync(
          p,
          apply: widget.profiles.activeId == p.id,
          manageBusy: false,
          quiet: true,
        );
      }
      await _snack('已刷新 ${list.length} 个订阅');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addDialog() async {
    final nameCtrl = TextEditingController();
    final contentCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加配置'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '名称（可选）',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentCtrl,
                minLines: 4,
                maxLines: 12,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '订阅 URL / 分享链接 / sing-box JSON',
                  alignLabelWithHint: true,
                  hintText:
                      'https://…\nvless://…\n或粘贴完整 sing-box JSON',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '支持：Clash 订阅链接、ss/vmess/vless/trojan/hy2 分享链接、'
                'sing-box JSON（完整配置或单个 outbound）',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final content = contentCtrl.text.trim();
    if (content.isEmpty) {
      await _snack('请填写 URL、分享链接或 JSON');
      return;
    }

    final firstLine = content.split(RegExp(r'\r?\n')).first.trim();
    final lower = firstLine.toLowerCase();
    final isShare = lower.startsWith('ss://') ||
        lower.startsWith('vmess://') ||
        lower.startsWith('vless://') ||
        lower.startsWith('trojan://') ||
        lower.startsWith('hysteria2://') ||
        lower.startsWith('hy2://');
    final isHttp = !isShare &&
        (firstLine.startsWith('http://') || firstLine.startsWith('https://'));
    final url = isHttp ? firstLine : '';

    setState(() => _busy = true);
    try {
    final profile = await widget.profiles.add(
      name: nameCtrl.text.trim(),
      url: url,
      kind: isHttp ? ProfileKind.remote : ProfileKind.local,
      autoUpdate: isHttp,
    );
      final result = await widget.subscriptions.importFromText(
        content,
        configFileName: profile.resolvedConfigFileName,
        profileName: profile.name,
      );
      if (!result.ok || result.configPath == null) {
        await widget.profiles.remove(profile.id);
        await _snack(result.message);
        return;
      }

      final named = nameCtrl.text.trim().isNotEmpty
          ? nameCtrl.text.trim()
          : (result.profileName ?? profile.name);
      await widget.profiles.update(
        profile.copyWith(
          name: named,
          mappedCount: result.mappedCount,
          proxyTotal: result.proxyCount,
          updatedAt: DateTime.now(),
        ),
      );

      final shouldApply = widget.profiles.profiles.length == 1 ||
          widget.profiles.activeId == null ||
          widget.profiles.activeId == profile.id;
      if (shouldApply) {
        await widget.profiles.setActive(profile.id);
        try {
          final path = await widget.profiles.activeConfigPath();
          if (path != null) {
            await _applyRunningCore(path);
          }
        } catch (_) {}
        widget.onApplied?.call();
      }

      if (mounted) setState(() {});
      await _snack(result.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(SubscriptionProfile profile) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('确定删除「${profile.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (_editingId == profile.id) _editingId = null;
    await widget.profiles.remove(profile.id);
    setState(() {});
  }

  Future<void> _saveEdit(SubscriptionProfile edited) async {
    await widget.profiles.update(edited);
    setState(() => _editingId = null);
    await _snack('已保存');
  }

  List<Widget> _profileSection({
    required String title,
    required List<SubscriptionProfile> profiles,
    required ColorScheme scheme,
  }) {
    if (profiles.isEmpty) return const [];
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Text(
            '$title · ${profiles.length}',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 360,
            mainAxisExtent: 96,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final p = profiles[i];
              final selected = p.id == widget.profiles.activeId;
              return _ProfileCard(
                profile: p,
                selected: selected,
                onTap: () => _select(p),
                onEdit: () => setState(() => _editingId = p.id),
                onSync: () => _sync(
                  p,
                  apply: p.id == widget.profiles.activeId,
                ),
                onCopyLink: () async {
                  if (p.isLocal || p.url.isEmpty) {
                    await _snack(p.isLocal ? '本地订阅无远程链接' : '无链接可复制');
                    return;
                  }
                  await Clipboard.setData(ClipboardData(text: p.url));
                  await _snack('已复制链接');
                },
                onStub: (label) => _snack('$label（即将支持）'),
                onDelete: () => _delete(p),
              );
            },
            childCount: profiles.length,
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final editing = _editing;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '配置',
                        style:
                            Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新全部',
                      onPressed: _busy ? null : _refreshAll,
                      icon: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '筛选',
                      onSelected: (v) => setState(() => _sort = v),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'updated',
                          child: Text('按更新时间'),
                        ),
                        PopupMenuItem(
                          value: 'name',
                          child: Text('按名称'),
                        ),
                      ],
                      icon: const Icon(Icons.tune),
                    ),
                    IconButton(
                      tooltip: '添加',
                      onPressed: _busy ? null : _addDialog,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: widget.profiles.profiles.isEmpty
                    ? Center(
                        child: Text(
                          '暂无配置，点击右上角 + 导入订阅 / 分享链接 / JSON',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : CustomScrollView(
                        slivers: [
                          ..._profileSection(
                            title: ProfileKind.remote.label,
                            profiles: _remoteProfiles,
                            scheme: scheme,
                          ),
                          ..._profileSection(
                            title: ProfileKind.local.label,
                            profiles: _localProfiles,
                            scheme: scheme,
                          ),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 20),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        if (editing != null)
          _EditPanel(
            key: ValueKey(editing.id),
            profile: editing,
            onClose: () => setState(() => _editingId = null),
            onSave: _saveEdit,
          ),
      ],
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onSync,
    required this.onCopyLink,
    required this.onStub,
    required this.onDelete,
  });

  final SubscriptionProfile profile;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onSync;
  final VoidCallback onCopyLink;
  final void Function(String label) onStub;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expire = ProfileFormat.expirePill(profile.expireAt);
    final traffic = ProfileFormat.trafficLine(
      used: profile.usedBytes,
      total: profile.total,
    );
    final updated = ProfileFormat.relativeTime(profile.updatedAt);

    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.4 : 0.8,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onSecondaryTapDown: (d) => _openMenu(context, d.globalPosition),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            profile.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (profile.isLocal) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.tertiary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '本地',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: scheme.tertiary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                        if (expire.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              expire,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Text(
                    updated,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                  if (selected)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.check_circle,
                        size: 20,
                        color: scheme.primary,
                      ),
                    ),
                  PopupMenuButton<_CardAction>(
                    tooltip: '更多',
                    onSelected: (a) {
                      switch (a) {
                        case _CardAction.edit:
                          onEdit();
                        case _CardAction.sync:
                          onSync();
                        case _CardAction.copy:
                          onCopyLink();
                        case _CardAction.qr:
                          onStub('二维码');
                        case _CardAction.export:
                          onStub('导出文件');
                        case _CardAction.runtime:
                          onStub('运行时配置');
                        case _CardAction.delete:
                          onDelete();
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: _CardAction.edit,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.edit_outlined),
                          title: Text('编辑'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      if (!profile.isLocal)
                        const PopupMenuItem(
                          value: _CardAction.sync,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.sync),
                            title: Text('同步'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: _CardAction.runtime,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.visibility_outlined),
                          title: Text('运行时配置'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      if (!profile.isLocal)
                        const PopupMenuItem(
                          value: _CardAction.copy,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.copy_outlined),
                            title: Text('复制链接'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      if (!profile.isLocal)
                        const PopupMenuItem(
                          value: _CardAction.qr,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.qr_code_2),
                            title: Text('二维码'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      const PopupMenuItem(
                        value: _CardAction.export,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.upload_outlined),
                          title: Text('导出文件'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: _CardAction.delete,
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.delete_outline,
                            color: scheme.error,
                          ),
                          title: Text(
                            '删除',
                            style: TextStyle(color: scheme.error),
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const Spacer(),
              Text(
                profile.isLocal
                    ? (profile.proxyTotal != null
                        ? '本地 · ${profile.mappedCount ?? profile.proxyTotal} 节点'
                        : '本地导入')
                    : traffic,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openMenu(BuildContext context, Offset global) {
    // Secondary click uses the same PopupMenuButton via long-press menu alternative:
    // show a positioned menu mirroring card actions.
    final scheme = Theme.of(context).colorScheme;
    showMenu<_CardAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        global.dx,
        global.dy,
        global.dx + 1,
        global.dy + 1,
      ),
      items: [
        const PopupMenuItem(value: _CardAction.edit, child: Text('编辑')),
        if (!profile.isLocal)
          const PopupMenuItem(value: _CardAction.sync, child: Text('同步')),
        if (!profile.isLocal)
          const PopupMenuItem(value: _CardAction.copy, child: Text('复制链接')),
        PopupMenuItem(
          value: _CardAction.delete,
          child: Text('删除', style: TextStyle(color: scheme.error)),
        ),
      ],
    ).then((a) {
      if (a == null) return;
      switch (a) {
        case _CardAction.edit:
          onEdit();
        case _CardAction.sync:
          onSync();
        case _CardAction.copy:
          onCopyLink();
        case _CardAction.delete:
          onDelete();
        default:
          break;
      }
    });
  }
}

enum _CardAction { edit, sync, copy, qr, export, runtime, delete }

class _EditPanel extends StatefulWidget {
  const _EditPanel({
    super.key,
    required this.profile,
    required this.onClose,
    required this.onSave,
  });

  final SubscriptionProfile profile;
  final VoidCallback onClose;
  final Future<void> Function(SubscriptionProfile edited) onSave;

  @override
  State<_EditPanel> createState() => _EditPanelState();
}

class _EditPanelState extends State<_EditPanel> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _interval;
  late bool _autoUpdate;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.profile.name);
    _url = TextEditingController(text: widget.profile.url);
    _interval = TextEditingController(
      text: '${widget.profile.autoUpdateIntervalMin}',
    );
    _autoUpdate = widget.profile.autoUpdate;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _interval.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final interval = int.tryParse(_interval.text.trim()) ?? 1440;
    final edited = widget.profile.isLocal
        ? widget.profile.copyWith(
            name: _name.text.trim().isEmpty
                ? widget.profile.name
                : _name.text.trim(),
            autoUpdate: false,
          )
        : widget.profile.copyWith(
            name: _name.text.trim().isEmpty
                ? widget.profile.name
                : _name.text.trim(),
            url: _url.text.trim(),
            autoUpdate: _autoUpdate,
            autoUpdateIntervalMin: interval < 1 ? 1440 : interval,
          );
    await widget.onSave(edited);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 2,
      color: scheme.surface,
      child: SizedBox(
        width: 320,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '关闭',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                  Expanded(
                    child: Text(
                      '编辑',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: '保存',
                    onPressed: _save,
                    icon: const Icon(Icons.check),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('类型'),
                    trailing: Text(
                      widget.profile.kind.label,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '名称'),
                  ),
                  if (widget.profile.isRemote) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _url,
                      decoration: const InputDecoration(labelText: 'URL'),
                      keyboardType: TextInputType.url,
                    ),
                    const SizedBox(height: 20),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('自动更新'),
                      value: _autoUpdate,
                      onChanged: (v) => setState(() => _autoUpdate = v),
                    ),
                    TextField(
                      controller: _interval,
                      enabled: _autoUpdate,
                      decoration: const InputDecoration(
                        labelText: '自动更新间隔（分钟）',
                        suffixText: '分钟',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    Text(
                      '由分享链接或 sing-box JSON 导入，无法远程同步。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('更新时间'),
                    subtitle: Text(
                      ProfileFormat.relativeTime(widget.profile.updatedAt),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
