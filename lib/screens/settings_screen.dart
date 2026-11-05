import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/config_store.dart';
import '../services/helper_channel.dart';
import '../services/rule_set_store.dart';
import '../services/singbox_core_channel.dart';
import '../services/system_proxy_channel.dart';
import '../services/tun_config.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.helper,
    required this.core,
    required this.configStore,
  });

  final HelperChannel helper;
  final SingboxCoreChannel core;
  final ConfigStore configStore;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _proxy = SystemProxyChannel();
  final _settingsStore = AppSettingsStore();
  final _localDnsCtrl = TextEditingController();
  final _remoteDnsCtrl = TextEditingController();
  final _intranetDnsCtrl = TextEditingController();
  final _mixedPortCtrl = TextEditingController();
  final _httpPortCtrl = TextEditingController();
  final _socksPortCtrl = TextEditingController();
  DnsQueryStrategy _dnsStrategy = DnsQueryStrategy.race;

  String _helperStatus = '…';
  String _coreVersion = '…';
  Map<String, dynamic> _coreStatus = const {};
  bool _installed = false;
  bool _busy = false;
  bool _dnsSaving = false;
  bool _dnsDirty = false;
  bool _dnsHydrating = false;
  bool _portsSaving = false;
  bool _portsDirty = false;
  bool _portsHydrating = false;
  bool _routeEnabled = true;
  bool _routePrivateDirect = true;
  bool _routeChinaDirect = true;
  bool _routeBlockAds = false;
  List<CustomRouteRule> _customRules = const [];
  bool _routeSaving = false;
  bool _ruleSetUpdating = false;
  DateTime? _ruleSetUpdatedAt;
  bool _tunReachable = false;
  bool _tunRunning = false;
  bool _proxyManaged = false;
  bool _proxyAnyOn = false;

  @override
  void initState() {
    super.initState();
    _localDnsCtrl.addListener(_onDnsEdited);
    _remoteDnsCtrl.addListener(_onDnsEdited);
    _intranetDnsCtrl.addListener(_onDnsEdited);
    _mixedPortCtrl.addListener(_onPortsEdited);
    _httpPortCtrl.addListener(_onPortsEdited);
    _socksPortCtrl.addListener(_onPortsEdited);
    _refresh();
    _loadAppSettings();
    _loadRuleSetMeta();
  }

  @override
  void dispose() {
    _localDnsCtrl.removeListener(_onDnsEdited);
    _remoteDnsCtrl.removeListener(_onDnsEdited);
    _intranetDnsCtrl.removeListener(_onDnsEdited);
    _mixedPortCtrl.removeListener(_onPortsEdited);
    _httpPortCtrl.removeListener(_onPortsEdited);
    _socksPortCtrl.removeListener(_onPortsEdited);
    _localDnsCtrl.dispose();
    _remoteDnsCtrl.dispose();
    _intranetDnsCtrl.dispose();
    _mixedPortCtrl.dispose();
    _httpPortCtrl.dispose();
    _socksPortCtrl.dispose();
    super.dispose();
  }

  void _onDnsEdited() {
    if (_dnsHydrating || _dnsDirty) return;
    setState(() => _dnsDirty = true);
  }

  void _onPortsEdited() {
    if (_portsHydrating || _portsDirty) return;
    setState(() => _portsDirty = true);
  }

  Future<void> _loadAppSettings() async {
    final settings = await _settingsStore.load();
    if (!mounted) return;
    _dnsHydrating = true;
    _portsHydrating = true;
    _localDnsCtrl.text = settings.dns.localAddressesText();
    _remoteDnsCtrl.text = settings.dns.remoteAddressesText();
    _intranetDnsCtrl.text = settings.dns.intranetSuffixesText();
    _mixedPortCtrl.text = '${settings.ports.mixedPort}';
    _httpPortCtrl.text = '${settings.ports.httpPort}';
    _socksPortCtrl.text = '${settings.ports.socksPort}';
    _dnsHydrating = false;
    _portsHydrating = false;
    setState(() {
      _dnsStrategy = settings.dns.strategy;
      _dnsDirty = false;
      _portsDirty = false;
      _routeEnabled = settings.route.enabled;
      _routePrivateDirect = settings.route.privateDirect;
      _routeChinaDirect = settings.route.chinaDirect;
      _routeBlockAds = settings.route.blockAds;
      _customRules = List<CustomRouteRule>.from(settings.route.customRules);
    });
  }

  Future<void> _loadRuleSetMeta() async {
    final at = await RuleSetStore().lastUpdatedAt();
    if (!mounted) return;
    setState(() => _ruleSetUpdatedAt = at);
  }

  String _formatRuleSetUpdatedAt() {
    final at = _ruleSetUpdatedAt;
    if (at == null) return '尚未手动更新（首次连接也可能在线拉取）';
    final l = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '上次更新 ${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }

  Future<void> _updateRuleSets() async {
    if (_ruleSetUpdating) return;
    if (!_routeEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先开启默认分流')),
      );
      return;
    }
    setState(() => _ruleSetUpdating = true);
    try {
      final route = BypassRouteSettings(
        enabled: _routeEnabled,
        privateDirect: _routePrivateDirect,
        chinaDirect: _routeChinaDirect,
        blockAds: _routeBlockAds,
        customRules: _customRules,
      );
      final result = await RuleSetStore().updateEnabled(route);
      final path = await widget.configStore.resolveDefaultConfigPath();
      await widget.configStore.reapplyUserSettings(path: path, route: route);

      final suffix = await _reloadCoreAfterRouteChange(path);

      await _loadRuleSetMeta();
      if (!mounted) return;
      setState(() => _ruleSetUpdating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.ok ? '${result.message}$suffix' : result.message,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _ruleSetUpdating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新失败: $e')),
      );
    }
  }

  /// Reload running core (TUN helper or in-app) so route changes take effect.
  Future<String> _reloadCoreAfterRouteChange(String path) async {
    try {
      final tun = await widget.helper.tunStatus();
      if (tun.reachable && tun.running) {
        // Helper start waits for ports after stopping in-app core only;
        // must stop helper first or 7890/9090 stay held.
        final port = await TunConfig.mixedPortFromConfig(path);
        await widget.helper.tunStop(httpPort: port, apiPort: 9090);
        try {
          if (await widget.core.isRunning()) {
            await widget.core.stop();
          }
        } catch (_) {}
        final tunPath = await TunConfig.writeTunVariant(path);
        await widget.helper.tunStart(
          configPath: tunPath,
          clashApiBaseUrl: 'http://127.0.0.1:9090',
          httpPort: port,
          apiPort: 9090,
        );
        return '；TUN 已重载';
      }
    } catch (_) {
      return '；TUN 重载失败，请到首页开关一次 TUN';
    }
    try {
      await widget.core.applyConfig(path);
      return '；内核已重载';
    } catch (_) {
      return '；请手动重新连接内核';
    }
  }

  Future<void> _saveRouteSettings({
    bool? enabled,
    bool? privateDirect,
    bool? chinaDirect,
    bool? blockAds,
    List<CustomRouteRule>? customRules,
  }) async {
    final next = BypassRouteSettings(
      enabled: enabled ?? _routeEnabled,
      privateDirect: privateDirect ?? _routePrivateDirect,
      chinaDirect: chinaDirect ?? _routeChinaDirect,
      blockAds: blockAds ?? _routeBlockAds,
      customRules: customRules ?? _customRules,
    );
    setState(() {
      _routeSaving = true;
      _routeEnabled = next.enabled;
      _routePrivateDirect = next.privateDirect;
      _routeChinaDirect = next.chinaDirect;
      _routeBlockAds = next.blockAds;
      _customRules = List<CustomRouteRule>.from(next.customRules);
    });
    try {
      final current = await _settingsStore.load();
      await _settingsStore.save(current.copyWith(route: next));
      await widget.configStore.reapplyUserSettings(route: next);
      final path = await widget.configStore.resolveDefaultConfigPath();
      final suffix = await _reloadCoreAfterRouteChange(path);
      if (!mounted) return;
      setState(() => _routeSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('分流规则已保存$suffix')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _routeSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
  }

  Future<void> _editCustomRule({CustomRouteRule? existing, int? index}) async {
    final result = await showDialog<CustomRouteRule>(
      context: context,
      builder: (ctx) => _CustomRuleDialog(initial: existing),
    );
    if (result == null || !mounted) return;
    final next = List<CustomRouteRule>.from(_customRules);
    if (index != null) {
      next[index] = result;
    } else {
      next.add(result);
    }
    await _saveRouteSettings(customRules: next);
  }

  Future<void> _deleteCustomRule(int index) async {
    final next = List<CustomRouteRule>.from(_customRules)..removeAt(index);
    await _saveRouteSettings(customRules: next);
  }

  Future<void> _toggleCustomRule(int index, bool enabled) async {
    final next = List<CustomRouteRule>.from(_customRules);
    next[index] = next[index].copyWith(enabled: enabled);
    await _saveRouteSettings(customRules: next);
  }

  Future<void> _moveCustomRule(int index, int delta) async {
    final dest = index + delta;
    if (dest < 0 || dest >= _customRules.length) return;
    final next = List<CustomRouteRule>.from(_customRules);
    final item = next.removeAt(index);
    next.insert(dest, item);
    await _saveRouteSettings(customRules: next);
  }

  Future<void> _saveDnsSettings() async {
    final local = DnsSettings.parseAddressText(_localDnsCtrl.text);
    final remote = DnsSettings.parseAddressText(_remoteDnsCtrl.text);
    final intranet = DnsSettings.parseAddressText(_intranetDnsCtrl.text);
    if (local.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('直连 DNS 至少需要一个地址')),
      );
      return;
    }
    if (remote.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('代理 DNS 至少需要一个地址')),
      );
      return;
    }

    setState(() => _dnsSaving = true);
    try {
      final dns = DnsSettings(
        localAddresses: local,
        remoteAddresses: remote,
        strategy: _dnsStrategy,
        intranetSuffixes: intranet,
      );
      final current = await _settingsStore.load();
      await _settingsStore.save(current.copyWith(dns: dns));
      await widget.configStore.reapplyUserSettings(dns: dns);
      final path = await widget.configStore.resolveDefaultConfigPath();
      final suffix = await _reloadCoreAfterRouteChange(path);
      if (!mounted) return;
      _dnsHydrating = true;
      _localDnsCtrl.text = dns.localAddressesText();
      _remoteDnsCtrl.text = dns.remoteAddressesText();
      _intranetDnsCtrl.text = dns.intranetSuffixesText();
      _dnsHydrating = false;
      setState(() {
        _dnsStrategy = dns.strategy;
        _dnsSaving = false;
        _dnsDirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('DNS 已保存$suffix')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _dnsSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
  }

  int? _parsePortField(String raw, {required bool allowZero}) {
    final s = raw.trim();
    if (s.isEmpty) return allowZero ? 0 : null;
    final n = int.tryParse(s);
    if (n == null) return null;
    if (allowZero && n == 0) return 0;
    if (n < 1 || n > 65535) return null;
    return n;
  }

  Future<void> _savePortSettings() async {
    final mixed = _parsePortField(_mixedPortCtrl.text, allowZero: true);
    final http = _parsePortField(_httpPortCtrl.text, allowZero: true);
    final socks = _parsePortField(_socksPortCtrl.text, allowZero: true);
    if (mixed == null || http == null || socks == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('端口须为 0–65535 的整数（0 表示关闭）')),
      );
      return;
    }
    if (mixed == 0 && http == 0 && socks == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('至少开启一个代理端口')),
      );
      return;
    }
    final used = <int, String>{};
    for (final e in [
      (mixed, 'Mixed'),
      (http, 'HTTP'),
      (socks, 'Socks'),
    ]) {
      if (e.$1 == 0) continue;
      final prev = used[e.$1];
      if (prev != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${e.$2} 与 $prev 端口冲突（${e.$1}）')),
        );
        return;
      }
      used[e.$1] = e.$2;
    }

    setState(() => _portsSaving = true);
    try {
      final ports = PortSettings(
        mixedPort: mixed,
        httpPort: http,
        socksPort: socks,
      );
      final current = await _settingsStore.load();
      await _settingsStore.save(current.copyWith(ports: ports));
      await widget.configStore.reapplyUserSettings(ports: ports);
      if (!mounted) return;
      _portsHydrating = true;
      _mixedPortCtrl.text = '${ports.mixedPort}';
      _httpPortCtrl.text = '${ports.httpPort}';
      _socksPortCtrl.text = '${ports.socksPort}';
      _portsHydrating = false;
      setState(() {
        _portsSaving = false;
        _portsDirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('端口已保存；重新连接后生效')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _portsSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
  }

  Future<void> _resetDnsDefaults() async {
    final dns = DnsSettings.defaults;
    _dnsHydrating = true;
    _localDnsCtrl.text = dns.localAddressesText();
    _remoteDnsCtrl.text = dns.remoteAddressesText();
    _intranetDnsCtrl.text = dns.intranetSuffixesText();
    _dnsHydrating = false;
    setState(() {
      _dnsStrategy = dns.strategy;
      _dnsDirty = true;
    });
  }

  Future<void> _resetPortDefaults() async {
    final ports = PortSettings.defaults;
    _portsHydrating = true;
    _mixedPortCtrl.text = '${ports.mixedPort}';
    _httpPortCtrl.text = '${ports.httpPort}';
    _socksPortCtrl.text = '${ports.socksPort}';
    _portsHydrating = false;
    setState(() => _portsDirty = true);
  }

  Future<void> _refresh() async {
    final status = await widget.helper.statusText();
    final installed = await widget.helper.isInstalled();
    final version = await widget.core.version();
    final coreStatus = await widget.core.status();
    final proxy = await _proxy.status();
    TunHelperStatus tun = const TunHelperStatus(reachable: false);
    if (installed) {
      tun = await widget.helper.tunStatus();
    }
    if (!mounted) return;
    setState(() {
      _helperStatus = status;
      _installed = installed;
      _coreVersion = version;
      _coreStatus = coreStatus;
      _proxyManaged = proxy.managed;
      _proxyAnyOn = proxy.anyProxyOn;
      _tunReachable = tun.reachable;
      _tunRunning = tun.running;
    });
  }

  Future<void> _install() async {
    setState(() => _busy = true);
    try {
      final result = await widget.helper.install();
      await _refresh();
      if (!mounted) return;
      setState(() => _busy = false);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(result.ok ? '安装成功' : '安装结果'),
          content: Text(result.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('好'),
            ),
          ],
        ),
      );
    } on HelperInstallException catch (e) {
      await _refresh();
      if (!mounted) return;
      setState(() => _busy = false);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(e.code == 'cancelled' ? '已取消' : '安装失败'),
          content: Text(e.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('好'),
            ),
          ],
        ),
      );
    } catch (e) {
      await _refresh();
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _coreStatus['running'] == true || _tunRunning;
    final configPath = _coreStatus['configPath']?.toString();
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('设置', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.lan_outlined, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('端口', style: theme.textTheme.titleMedium),
                    ),
                    TextButton(
                      onPressed: _portsSaving ? null : _resetPortDefaults,
                      child: const Text('恢复默认'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '本地代理监听端口。0 表示关闭该入口；至少开启一个。'
                  '系统代理优先使用 Mixed。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _mixedPortCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Mixed 端口',
                          hintText: '7890',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _httpPortCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'HTTP 端口',
                          hintText: '0',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _socksPortCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Socks 端口',
                          hintText: '0',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed:
                        (_portsSaving || !_portsDirty) ? null : _savePortSettings,
                    icon: _portsSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(_portsSaving ? '保存中…' : '保存端口'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.alt_route,
                    color: theme.colorScheme.primary,
                  ),
                  title: Text('默认分流', style: theme.textTheme.titleMedium),
                  subtitle: Text(
                    'SagerNet rule-set：局域网 / 国内直连 / 广告拦截。'
                    '可点下方按钮更新到本地。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: Switch(
                    value: _routeEnabled,
                    onChanged: _routeSaving
                        ? null
                        : (v) => _saveRouteSettings(enabled: v),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('局域网直连'),
                  subtitle: const Text('ip_is_private → direct（有本地 geoip-private 则优先）'),
                  value: _routePrivateDirect,
                  onChanged: (!_routeEnabled || _routeSaving)
                      ? null
                      : (v) => _saveRouteSettings(privateDirect: v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('国内直连'),
                  subtitle: const Text('geosite-cn / geoip-cn → direct'),
                  value: _routeChinaDirect,
                  onChanged: (!_routeEnabled || _routeSaving)
                      ? null
                      : (v) => _saveRouteSettings(chinaDirect: v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('广告拦截'),
                  subtitle: const Text('category-ads-all → block'),
                  value: _routeBlockAds,
                  onChanged: (!_routeEnabled || _routeSaving)
                      ? null
                      : (v) => _saveRouteSettings(blockAds: v),
                ),
                const Divider(height: 16),
                Text(
                  '规则集来自 SagerNet（jsDelivr）：cn / ads；可选 geoip-private。'
                  '局域网默认用内置 ip_is_private，避免缺文件无法启动；'
                  '手动更新成功后会优先用本地 .srs。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _formatRuleSetUpdatedAt(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: (_routeSaving ||
                            _ruleSetUpdating ||
                            !_routeEnabled)
                        ? null
                        : _updateRuleSets,
                    icon: _ruleSetUpdating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_download_outlined),
                    label: Text(_ruleSetUpdating ? '更新中…' : '更新规则集'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.rule, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('自定义规则', style: theme.textTheme.titleMedium),
                    ),
                    TextButton.icon(
                      onPressed: _routeSaving ? null : () => _editCustomRule(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加'),
                    ),
                  ],
                ),
                Text(
                  '优先于国内直连 / 广告规则。列表从上到下匹配；'
                  '出站「代理」指向当前策略组。'
                  '「进程名」填写可执行文件名（如 WeChat），TUN 下常用作直连。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                if (_customRules.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '暂无自定义规则',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  for (var i = 0; i < _customRules.length; i++)
                    _CustomRuleTile(
                      rule: _customRules[i],
                      index: i,
                      total: _customRules.length,
                      busy: _routeSaving,
                      onToggle: (v) => _toggleCustomRule(i, v),
                      onEdit: () => _editCustomRule(
                        existing: _customRules[i],
                        index: i,
                      ),
                      onDelete: () => _deleteCustomRule(i),
                      onMoveUp: () => _moveCustomRule(i, -1),
                      onMoveDown: () => _moveCustomRule(i, 1),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.dns_outlined, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('DNS', style: theme.textTheme.titleMedium),
                    ),
                    TextButton(
                      onPressed: _dnsSaving ? null : _resetDnsDefaults,
                      child: const Text('恢复默认'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '真实解析，无 fake-ip。每行一个地址，支持 IP / udp:// / tls:// / https://。'
                  '多个地址由下方策略真正生效（需当前内核支持多 DNS 组）。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Text('多地址策略', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                SegmentedButton<DnsQueryStrategy>(
                  segments: [
                    for (final s in DnsQueryStrategy.values)
                      ButtonSegment(
                        value: s,
                        label: Text(s.label),
                        tooltip: s.hint,
                      ),
                  ],
                  selected: {_dnsStrategy},
                  onSelectionChanged: _dnsSaving
                      ? null
                      : (next) {
                          if (next.isEmpty) return;
                          setState(() {
                            _dnsStrategy = next.first;
                            _dnsDirty = true;
                          });
                        },
                ),
                const SizedBox(height: 6),
                Text(
                  _dnsStrategy.hint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _localDnsCtrl,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '直连 DNS',
                    alignLabelWithHint: true,
                    hintText: '192.168.100.1\n223.5.5.5',
                    border: OutlineInputBorder(),
                    helperText: '请包含路由器/内网 DNS（私网 IP），TUN 下内网域名会优先问它',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _remoteDnsCtrl,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '代理 DNS',
                    alignLabelWithHint: true,
                    hintText: 'https://1.1.1.1/dns-query',
                    border: OutlineInputBorder(),
                    helperText: '经节点出站查询（建议 DoH/DoT）',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _intranetDnsCtrl,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '内网域名后缀',
                    alignLabelWithHint: true,
                    hintText: 'local\nlan\ncorp.example',
                    border: OutlineInputBorder(),
                    helperText:
                        'TUN 劫持 DNS 时走局域网 DNS；无点主机名（如 nas）也会走内网解析',
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: (_dnsSaving || !_dnsDirty) ? null : _saveDnsSettings,
                    icon: _dnsSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(_dnsSaving ? '保存中…' : '保存 DNS'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(
                  _installed ? Icons.verified_user : Icons.security,
                ),
                title: const Text('Privileged Helper'),
                subtitle: Text(_installed ? '已安装' : '未安装'),
                trailing: Text(_installed ? '就绪' : '需要安装'),
              ),
              if (_helperStatus.isNotEmpty && _installed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _helperStatus,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.cable),
                title: const Text('Helper Socket'),
                subtitle: Text(
                  _tunReachable
                      ? '可连接 · TUN ${_tunRunning ? "运行中" : "空闲"}'
                      : (_installed ? '未连通（需重装 0.3+ Helper）' : '—'),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.language),
                title: const Text('系统代理'),
                subtitle: Text(
                  _proxyManaged
                      ? '由 Singlet 管理中'
                      : (_proxyAnyOn ? '系统有其它代理开启' : '未由 Singlet 管理'),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : _install,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.admin_panel_settings_outlined),
                    label: Text(
                      _busy ? '安装中…' : (_installed ? '重新安装' : '一键安装'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ExpansionTile(
            leading: const Icon(Icons.memory),
            title: const Text('内核详情'),
            subtitle: Text(
              running
                  ? (_tunRunning ? '运行中（Helper/TUN）' : '运行中（应用内）')
                  : '已停止',
            ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              SelectableText('版本: $_coreVersion'),
              const SizedBox(height: 6),
              SelectableText(
                'Clash API: ${_coreStatus['clashApiBase'] ?? '—'}',
              ),
              if (configPath != null && configPath.isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectableText('配置: $configPath'),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _refresh,
          icon: const Icon(Icons.refresh),
          label: const Text('刷新'),
        ),
      ],
    );
  }
}

class _CustomRuleTile extends StatelessWidget {
  const _CustomRuleTile({
    required this.rule,
    required this.index,
    required this.total,
    required this.busy,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final CustomRouteRule rule;
  final int index;
  final int total;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = rule.value.trim().isEmpty
        ? '—'
        : rule.value.trim().split(RegExp(r'[\n,;]+')).first.trim();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
        title: Text('${rule.match.label} · ${rule.outbound.label}'),
        subtitle: Text(
          preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: Checkbox(
          value: rule.enabled,
          onChanged: busy ? null : (v) => onToggle(v ?? false),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '上移',
              onPressed: busy || index == 0 ? null : onMoveUp,
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: '下移',
              onPressed: busy || index >= total - 1 ? null : onMoveDown,
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
            IconButton(
              tooltip: '编辑',
              onPressed: busy ? null : onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: '删除',
              onPressed: busy ? null : onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomRuleDialog extends StatefulWidget {
  const _CustomRuleDialog({this.initial});

  final CustomRouteRule? initial;

  @override
  State<_CustomRuleDialog> createState() => _CustomRuleDialogState();
}

class _CustomRuleDialogState extends State<_CustomRuleDialog> {
  late CustomRuleMatch _match;
  late CustomRuleOutbound _outbound;
  late final TextEditingController _valueCtrl;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _match = initial?.match ?? CustomRuleMatch.domainSuffix;
    _outbound = initial?.outbound ?? CustomRuleOutbound.proxy;
    _valueCtrl = TextEditingController(text: initial?.value ?? '');
    _enabled = initial?.enabled ?? true;
  }

  @override
  void dispose() {
    _valueCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? '添加规则' : '编辑规则'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<CustomRuleMatch>(
              // ignore: deprecated_member_use
              value: _match,
              decoration: const InputDecoration(
                labelText: '匹配类型',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final m in CustomRuleMatch.values)
                  DropdownMenuItem(value: m, child: Text(m.label)),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _match = v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _valueCtrl,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: '匹配内容',
                hintText: _match.hint,
                helperText: _match == CustomRuleMatch.processName
                    ? '可执行文件名（活动监视器里的进程名），如 WeChat；可用逗号分隔多个'
                    : '多个值可用逗号或换行分隔',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<CustomRuleOutbound>(
              // ignore: deprecated_member_use
              value: _outbound,
              decoration: const InputDecoration(
                labelText: '出站',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final o in CustomRuleOutbound.values)
                  DropdownMenuItem(value: o, child: Text(o.label)),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _outbound = v);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final value = _valueCtrl.text.trim();
            if (value.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请填写匹配内容')),
              );
              return;
            }
            final id = widget.initial?.id ??
                DateTime.now().microsecondsSinceEpoch.toString();
            Navigator.of(context).pop(
              CustomRouteRule(
                id: id,
                match: _match,
                value: value,
                outbound: _outbound,
                enabled: _enabled,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
