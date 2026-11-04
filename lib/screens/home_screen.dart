import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/clash_api_client.dart';
import '../services/config_store.dart';
import '../services/helper_channel.dart';
import '../services/profile_store.dart';
import '../services/singbox_core_channel.dart';
import '../services/system_proxy_channel.dart';
import '../services/tun_config.dart';

/// Clash Verge–style dashboard (Material 3).
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.core,
    required this.configStore,
    required this.clashApi,
    required this.helper,
    this.profileStore,
  });

  final SingboxCoreChannel core;
  final ConfigStore configStore;
  final ClashApiClient clashApi;
  final HelperChannel helper;
  final ProfileStore? profileStore;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _modes = ['rule', 'global', 'direct'];
  static const _modeLabels = {'rule': '规则', 'global': '全局', 'direct': '直连'};

  Timer? _poll;
  bool _busy = false;
  bool _running = false;
  bool _autoConnectAttempted = false;
  String? _error;

  // Live / API-backed
  String _mode = 'rule';
  bool _modeLive = false;
  int _upSpeed = 0;
  int _downSpeed = 0;
  bool _trafficLive = false;
  int _upTotal = 0;
  int _downTotal = 0;
  int _connCount = 0;
  int _connTotalSeen = 0;
  int _dnsActive = 0;
  bool _connLive = false;
  int? _memInuse;
  String _memSource = '';
  bool _helperInstalled = false;

  final _systemProxyChannel = SystemProxyChannel();
  bool _systemProxy = false;
  bool _tunEnabled = false;
  bool _proxyBusy = false;
  bool _tunBusy = false;

  // Sparkline history (last N speed samples) — must be growable for removeAt/add.
  final List<double> _upHistory = List<double>.filled(24, 0, growable: true);
  final List<double> _downHistory = List<double>.filled(24, 0, growable: true);

  DateTime? _connectedSince;
  int? _googleDelay;
  int? _githubDelay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // UI first: start polling immediately, connect in parallel.
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      unawaited(_bootstrap());
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }

    // Parallel probes — don't serialize Helper / proxy / API / core checks.
    final installedF = widget.helper.isInstalled();
    final proxyF = _systemProxyChannel.status();
    final apiF = widget.clashApi.isReachable();
    final inAppF = widget.core.isRunning();

    final installed = await installedF;
    final proxy = await proxyF;
    final apiUp = await apiF;
    final inApp = await inAppF;

    TunHelperStatus? tun;
    // Only ask Helper when this process is not already running the core.
    if (installed && !inApp) {
      tun = await widget.helper.tunStatus();
    }

    final helperTunLive = installed &&
        tun?.reachable == true &&
        tun?.running == true &&
        apiUp &&
        !inApp;

    if (!mounted) return;
    setState(() {
      _helperInstalled = installed;
      _systemProxy = proxy.managed;
      _tunEnabled = helperTunLive;
      _running = inApp || helperTunLive || apiUp;
      if (_running && _connectedSince == null) {
        _connectedSince = DateTime.now();
      }
    });

    if (helperTunLive || inApp || apiUp) {
      if (mounted) setState(() => _busy = false);
      unawaited(_tick());
      if (apiUp) unawaited(_probeDelays());
      return;
    }

    // Stale Helper "running" without API → stop then start in-app.
    if (tun?.running == true) {
      try {
        await widget.helper.tunStop(httpPort: 7890, apiPort: 9090);
      } catch (_) {}
      if (mounted) setState(() => _tunEnabled = false);
    }

    await _autoConnect(force: true);
    unawaited(_tick());
    if (mounted && _running) unawaited(_probeDelays());
  }

  Future<void> _refreshCore() async {
    final inAppF = widget.core.isRunning();
    final apiF = widget.clashApi.isReachable();
    final inApp = await inAppF;
    final apiUp = await apiF;
    var tun = false;
    if (_helperInstalled && !inApp) {
      final t = await widget.helper.tunStatus();
      // Helper 偶发 running 粘滞：必须 Clash API 可达且本进程未占内核。
      if (t.reachable && t.running && apiUp) {
        tun = true;
      }
    }
    final running = inApp || tun || apiUp;
    if (!mounted) return;
    setState(() {
      _tunEnabled = tun;
      _running = running;
      if (running && _connectedSince == null) {
        _connectedSince = DateTime.now();
      }
      if (!running) _connectedSince = null;
    });
  }

  Future<String> _configPath() async {
    final store = widget.profileStore;
    if (store != null) {
      await store.load();
      final path = await store.activeConfigPath();
      if (path != null) return path;
    }
    return widget.configStore.resolveDefaultConfigPath();
  }

  /// Active config with current DNS settings written in.
  Future<String> _prepareConfigPath() async {
    final path = await _configPath();
    await widget.configStore.reapplyDns(path: path);
    return path;
  }

  Future<void> _autoConnect({bool force = false}) async {
    if (_autoConnectAttempted && !force) return;
    _autoConnectAttempted = true;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Helper 侧若仍占 Clash API / Mixed 端口，应用内起核会报 listen 失败。
      await _ensurePortsFreeForInAppCore();
      final path = await _prepareConfigPath();
      await widget.core.applyConfig(path);
      await _refreshCore();
      if (!_running) {
        setState(() => _error = '启动失败');
      } else {
        unawaited(_probeDelays());
      }
    } catch (e) {
      if (mounted) setState(() => _error = _shortError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Stop Helper-owned core (if any) so in-app sing-box can bind Clash API / mixed.
  Future<void> _ensurePortsFreeForInAppCore() async {
    try {
      final tun = await widget.helper.tunStatus();
      if (tun.reachable && (tun.running || _tunEnabled)) {
        await widget.helper.tunStop(httpPort: 7890, apiPort: 9090);
        if (mounted) setState(() => _tunEnabled = false);
      }
    } catch (_) {
      // Helper 未装 / 不可达时忽略
    }
    // Best-effort: wait so bind is not racing Helper teardown.
    await _waitPortsBindable(const [7890, 9090], attempts: 40);
  }

  Future<void> _toggleCore() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_running || _tunEnabled) {
        if (_tunEnabled) {
          final path = await _configPath();
          final port = await TunConfig.mixedPortFromConfig(path);
          await widget.helper.tunStop(httpPort: port, apiPort: 9090);
          if (mounted) setState(() => _tunEnabled = false);
        }
        if (await widget.core.isRunning()) {
          await widget.core.stop();
        }
        if (_systemProxy) {
          await _systemProxyChannel.disable();
          if (mounted) setState(() => _systemProxy = false);
        }
      } else {
        await _ensurePortsFreeForInAppCore();
        final path = await _prepareConfigPath();
        await widget.core.start(
          configPath: path,
          clashApiBaseUrl: 'http://127.0.0.1:9090',
        );
      }
      await _refreshCore();
      if (_running) unawaited(_probeDelays());
    } catch (e) {
      if (mounted) setState(() => _error = _shortError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setSystemProxy(bool enable) async {
    if (_proxyBusy) return;
    setState(() => _proxyBusy = true);
    try {
      if (enable) {
        if (!_running && !_tunEnabled) {
          throw StateError('请先连接内核');
        }
        final path = await _configPath();
        final port = await TunConfig.mixedPortFromConfig(path);
        await _systemProxyChannel.enable(httpPort: port, socksPort: port);
        if (mounted) setState(() => _systemProxy = true);
      } else {
        await _systemProxyChannel.disable();
        if (mounted) setState(() => _systemProxy = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _systemProxy = !enable);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('系统代理失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _proxyBusy = false);
    }
  }

  Future<void> _setTun(bool enable) async {
    if (_tunBusy) return;
    if (enable && !_helperInstalled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在设置中安装 Privileged Helper')),
      );
      return;
    }
    setState(() => _tunBusy = true);
    try {
      if (enable) {
        final reachable = await widget.helper.tunPing();
        if (!reachable) {
          throw StateError(
            'Helper 未响应 /var/run/com.singlet.helper.sock，请到设置重新安装 Helper（需 0.3.1+）',
          );
        }
        // Release mixed/Clash ports in this process before helper binds them.
        try {
          if (await widget.core.isRunning()) {
            await widget.core.stop();
          }
        } catch (_) {}
        final basePath = await _prepareConfigPath();
        final port = await TunConfig.mixedPortFromConfig(basePath);
        final free = await _waitPortsBindable([port, 9090], attempts: 40);
        if (!free) {
          throw StateError(
            '端口 $port/9090 仍被占用，无法开启 TUN。请先断开再重试',
          );
        }
        final tunPath = await TunConfig.writeTunVariant(basePath);
        await widget.helper.tunStart(
          configPath: tunPath,
          clashApiBaseUrl: 'http://127.0.0.1:9090',
          httpPort: port,
          apiPort: 9090,
        );
        final st = await widget.helper.tunStatus();
        if (!st.running) {
          throw StateError('Helper 未保持运行（查看 /tmp/com.singlet.PrivilegedHelper.err.log）');
        }
        // macOS: LAN DHCP DNS never enters TUN — point resolver at TUN peers
        // so hijack-dns actually sees queries (fixes dnsleaktest / browserleaks).
        try {
          await _systemProxyChannel.enableTunDns(
            servers: TunConfig.tunDnsServers,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('TUN DNS 设置失败（可能仍会 DNS 泄漏）: $e'),
                duration: const Duration(seconds: 6),
              ),
            );
          }
        }
        widget.clashApi.resetConnectionTotals();
        if (mounted) {
          setState(() {
            _tunEnabled = true;
            _running = true;
            _connTotalSeen = 0;
            _dnsActive = 0;
          });
        }
        unawaited(_probeDelays());
      } else {
        // Hand off: Helper TUN → in-app core (proxy keeps working without TUN).
        await _handoffHelperToInAppCore();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _tunEnabled = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('TUN 失败: $e'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
      // Only recover when *enabling* TUN failed mid-way — re-running handoff
      // after a failed disable stacks more stop/Close and makes the race worse.
      if (enable) {
        try {
          await _handoffHelperToInAppCore();
        } catch (_) {}
      }
    } finally {
      if (mounted) setState(() => _tunBusy = false);
    }
  }

  /// Stop Helper-owned core, wait for Mixed/Clash ports, start in-app core.
  Future<void> _handoffHelperToInAppCore() async {
    final path = await _prepareConfigPath();
    final mixed = await TunConfig.mixedPortFromConfig(path);
    final ports = <int>{mixed, 9090}.toList();

    try {
      await widget.helper.tunStop(httpPort: mixed, apiPort: 9090);
    } catch (_) {}
    if (mounted) setState(() => _tunEnabled = false);

    // Also drop any leftover in-app listener before probing bind.
    try {
      if (await widget.core.isRunning()) {
        await widget.core.stop();
      }
    } catch (_) {}

    // Helper stop already drains ports; keep a generous local bind probe.
    var free = await _waitPortsBindable(ports, attempts: 80);
    if (!free) {
      try {
        await widget.helper.tunStop(httpPort: mixed, apiPort: 9090);
      } catch (_) {}
      try {
        if (await widget.core.isRunning()) {
          await widget.core.stop();
        }
      } catch (_) {}
      free = await _waitPortsBindable(ports, attempts: 100);
    }
    if (!free) {
      throw StateError(
        '关闭 TUN 后端口仍被占用（$mixed/9090）。请稍候重试或改设置里的端口',
      );
    }

    await widget.core.applyConfig(path);
    widget.clashApi.resetConnectionTotals();
    if (mounted) {
      setState(() {
        _running = true;
        _connTotalSeen = 0;
        _dnsActive = 0;
        _error = null;
      });
    }
    await _refreshCore();
    if (_running) unawaited(_probeDelays());
  }

  /// True when we can bind 127.0.0.1:port (stronger than connect-refused).
  Future<bool> _waitPortsBindable(
    List<int> ports, {
    int attempts = 40,
  }) async {
    for (var i = 0; i < attempts; i++) {
      if (await _canBindPorts(ports)) return true;
      // Back off — Helper SingletStop + TUN teardown can take many seconds.
      final ms = i < 20 ? 50 : (i < 50 ? 100 : 200);
      await Future<void>.delayed(Duration(milliseconds: ms));
    }
    return _canBindPorts(ports);
  }

  Future<bool> _canBindPorts(List<int> ports) async {
    final held = <ServerSocket>[];
    try {
      for (final p in ports) {
        if (p <= 0) continue;
        held.add(
          await ServerSocket.bind(InternetAddress.loopbackIPv4, p),
        );
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      for (final s in held) {
        await s.close();
      }
    }
  }

  Future<void> _tick() async {
    if (!mounted) return;
    final inApp = await widget.core.isRunning();
    final running = inApp || _tunEnabled;
    if (!mounted) return;

    if (!running) {
      setState(() {
        _running = false;
        _upSpeed = 0;
        _downSpeed = 0;
        _trafficLive = false;
        _connLive = false;
        _modeLive = false;
      });
      return;
    }
    if (mounted && !_running) {
      setState(() => _running = true);
    }

    final trafficF = widget.clashApi.peekTraffic();
    final connF = widget.clashApi.fetchConnections();
    final cfgF = widget.clashApi.fetchConfigs();
    final memF = _resolveMemory();
    final dnsF = _resolveDnsQueries();

    final traffic = await trafficF;
    final conn = await connF;
    final cfg = await cfgF;
    final mem = await memF;
    final dnsQueries = await dnsF;
    if (!mounted) return;

    setState(() {
      _running = true;
      _trafficLive = traffic.reachable;
      _upSpeed = traffic.up;
      _downSpeed = traffic.down;
      _pushHistory(_upHistory, traffic.up.toDouble());
      _pushHistory(_downHistory, traffic.down.toDouble());

      _connLive = conn.reachable;
      _connCount = conn.count;
      _connTotalSeen = conn.totalSeen;
      // Prefer engine counter: Clash /connections filters OutboundType DNS.
      _dnsActive = dnsQueries ?? conn.dnsActive;
      _upTotal = conn.uploadTotal;
      _downTotal = conn.downloadTotal;

      _modeLive = cfg.reachable;
      if (cfg.reachable) _mode = cfg.mode.toLowerCase();

      _memInuse = mem.$1;
      _memSource = mem.$2;
    });
  }

  void _pushHistory(List<double> hist, double v) {
    if (hist.isEmpty) {
      hist.add(v);
      return;
    }
    hist.removeAt(0);
    hist.add(v);
  }

  /// Prefer in-process MemStats; Helper only in TUN mode (skip Clash /memory — sing-box 404/0).
  Future<(int? inuse, String source)> _resolveMemory() async {
    if (!_tunEnabled) {
      final coreMem = await widget.core.memory();
      final coreInuse = _asMemInt(coreMem['inuse']);
      if (coreInuse != null && coreInuse > 0) {
        return (coreInuse, '内核 MemStats');
      }
      return (null, '');
    }
    if (_helperInstalled) {
      final tun = await widget.helper.tunStatus();
      if (tun.inuse != null && tun.inuse! > 0) {
        return (tun.inuse, 'Helper 内核');
      }
    }
    final coreMem = await widget.core.memory();
    final coreInuse = _asMemInt(coreMem['inuse']);
    if (coreInuse != null && coreInuse > 0) {
      return (coreInuse, '内核 MemStats');
    }
    return (null, '');
  }

  /// Cumulative DNS Exchange count from embedded core (works with hijack-dns).
  Future<int?> _resolveDnsQueries() async {
    if (_tunEnabled && _helperInstalled) {
      final tun = await widget.helper.tunStatus();
      if (tun.dnsQueries != null) return tun.dnsQueries;
    }
    final coreMem = await widget.core.memory();
    return _asMemInt(coreMem['dnsQueries']);
  }

  static int? _asMemInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  Future<void> _setMode(String mode) async {
    setState(() => _mode = mode);
    final ok = await widget.clashApi.setMode(mode);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('模式切换未生效（API 不可用或内核未支持）')),
      );
      final cfg = await widget.clashApi.fetchConfigs();
      if (mounted && cfg.reachable) {
        setState(() => _mode = cfg.mode.toLowerCase());
      }
    }
  }

  /// Prefer selector group used by the active subscription, else `direct`.
  Future<String> _delayProbeTarget() async {
    final catalog = await widget.clashApi.fetchProxyCatalog();
    if (catalog.reachable && catalog.groups.isNotEmpty) {
      for (final g in catalog.groups) {
        if (g.type == 'Selector' && g.name.toUpperCase() != 'GLOBAL') {
          return g.name;
        }
      }
      return catalog.groups.first.name;
    }
    return 'direct';
  }

  Future<void> _probeDelays() async {
    final target = await _delayProbeTarget();
    // Proxy-path health: Google / GitHub through current 节点选择 (or direct).
    final g = await widget.clashApi.testDelay(name: target);
    final gh = await widget.clashApi.testDelay(
      name: target,
      url: 'https://www.github.com/favicon.ico',
    );
    if (!mounted) return;
    setState(() {
      _googleDelay = g;
      _githubDelay = gh;
    });
  }

  String _shortError(Object e) {
    final s = '$e';
    final lower = s.toLowerCase();
    if (lower.contains('address already in use') ||
        lower.contains('external controller listen') ||
        lower.contains('bind:')) {
      return '端口被占用（Clash API / Mixed）。请先关 TUN/Helper 内核，或改设置里的端口';
    }
    if (s.length <= 80) return s;
    return '${s.substring(0, 80)}…';
  }

  String _uptime() {
    final since = _connectedSince;
    if (since == null || !_running) return '—';
    final d = DateTime.now().difference(since);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              sliver: SliverToBoxAdapter(
                child: Text(
                  '仪表盘',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ),
            if (_error != null)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Material(
                      color: scheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, color: scheme.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(color: scheme.onErrorContainer),
                              ),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _autoConnect(force: true),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              sliver: SliverToBoxAdapter(
                child: _DashboardGrid(
                  wide: wide,
                  status: _StatusCard(
                    running: _running,
                    busy: _busy,
                    uptime: _uptime(),
                    onToggle: _busy ? null : _toggleCore,
                  ),
                  up: _TrafficCard(
                    title: '上传',
                    speed: formatSpeed(_upSpeed),
                    peakHint: _trafficLive ? '实时' : 'API 离线',
                    total: formatBytes(_upTotal),
                    history: _upHistory,
                    live: _trafficLive,
                  ),
                  down: _TrafficCard(
                    title: '下载',
                    speed: formatSpeed(_downSpeed),
                    peakHint: _trafficLive ? '实时' : 'API 离线',
                    total: formatBytes(_downTotal),
                    history: _downHistory,
                    live: _trafficLive,
                  ),
                  mode: _ModeCard(
                    mode: _mode,
                    live: _modeLive,
                    labels: _modeLabels,
                    modes: _modes,
                    onChanged: _setMode,
                  ),
                  systemProxy: _ToggleCard(
                    title: '系统代理',
                    icon: Icons.language,
                    value: _systemProxy,
                    subtitle: _proxyBusy
                        ? '切换中…'
                        : (_systemProxy ? '已指向 mixed 入站' : '关闭'),
                    onChanged: _proxyBusy ? null : _setSystemProxy,
                  ),
                  tun: _ToggleCard(
                    title: '虚拟网卡',
                    icon: Icons.shield_outlined,
                    value: _tunEnabled,
                    subtitle: _tunBusy
                        ? '切换中…'
                        : (_helperInstalled
                            ? (_tunEnabled
                                ? 'Helper · TUN + 系统 DNS'
                                : 'Helper 已装')
                            : 'Helper 未装'),
                    onChanged: _tunBusy ? null : _setTun,
                  ),
                  delays: _DelayCard(
                    google: _googleDelay,
                    github: _githubDelay,
                    onRefresh: _probeDelays,
                  ),
                  memory: _MemoryCard(inuse: _memInuse, source: _memSource),
                  stats: _StatsCard(
                    connections: _connCount,
                    totalSeen: _connTotalSeen,
                    dnsActive: _dnsActive,
                    live: _connLive,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DashboardGrid extends StatelessWidget {
  const _DashboardGrid({
    required this.wide,
    required this.status,
    required this.up,
    required this.down,
    required this.mode,
    required this.systemProxy,
    required this.tun,
    required this.delays,
    required this.memory,
    required this.stats,
  });

  final bool wide;
  final Widget status;
  final Widget up;
  final Widget down;
  final Widget mode;
  final Widget systemProxy;
  final Widget tun;
  final Widget delays;
  final Widget memory;
  final Widget stats;

  @override
  Widget build(BuildContext context) {
    if (!wide) {
      return Column(
        children: [
          status,
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: up),
              const SizedBox(width: 12),
              Expanded(child: down),
            ],
          ),
          const SizedBox(height: 12),
          mode,
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: systemProxy),
              const SizedBox(width: 12),
              Expanded(child: tun),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: delays),
              const SizedBox(width: 12),
              Expanded(child: memory),
            ],
          ),
          const SizedBox(height: 12),
          stats,
        ],
      );
    }

    // Wide: mimic reference rhythm — status | traffic stack; mode + toggles; bottom row
    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: status),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: Column(
                  children: [
                    Expanded(child: up),
                    const SizedBox(height: 12),
                    Expanded(child: down),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        mode,
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: systemProxy),
              const SizedBox(width: 12),
              Expanded(child: tun),
            ],
          ),
        ),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: delays),
              const SizedBox(width: 12),
              Expanded(child: memory),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: stats),
            ],
          ),
        ),
      ],
    );
  }
}

class _DashCard extends StatelessWidget {
  const _DashCard({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.running,
    required this.busy,
    required this.uptime,
    required this.onToggle,
  });

  final bool running;
  final bool busy;
  final String uptime;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _DashCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '状态',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: running
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        busy && !running
                            ? '连接中'
                            : (running ? '运行中' : '已停止'),
                        style: TextStyle(
                          color: running
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  running ? '内核已连接' : '内核未连接',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  '运行时长  $uptime',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 72,
            height: 72,
            child: busy
                ? const Center(child: CircularProgressIndicator())
                : Material(
                    color: running ? scheme.primary : scheme.secondaryContainer,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onToggle,
                      child: Icon(
                        running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: 36,
                        color: running
                            ? scheme.onPrimary
                            : scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  const _TrafficCard({
    required this.title,
    required this.speed,
    required this.peakHint,
    required this.total,
    required this.history,
    required this.live,
  });

  final String title;
  final String speed;
  final String peakHint;
  final String total;
  final List<double> history;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _DashCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                Text(
                  speed,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                Text(
                  '累计 $total · $peakHint',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 88,
            height: 40,
            child: CustomPaint(
              painter: _SparkPainter(
                values: history,
                color: live ? scheme.primary : scheme.outlineVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final norm = maxV <= 0 ? 0.0 : values[i] / maxV;
      final y = size.height - norm * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.mode,
    required this.live,
    required this.labels,
    required this.modes,
    required this.onChanged,
  });

  final String mode;
  final bool live;
  final Map<String, String> labels;
  final List<String> modes;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = modes.contains(mode) ? mode : 'rule';
    return _DashCard(
      child: Row(
        children: [
          Text('出站模式', style: Theme.of(context).textTheme.titleMedium),
          if (!live) ...[
            const SizedBox(width: 8),
            Text(
              '本地',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
          const Spacer(),
          SegmentedButton<String>(
            segments: [
              for (final m in modes)
                ButtonSegment(value: m, label: Text(labels[m] ?? m)),
            ],
            selected: {selected},
            onSelectionChanged: (s) {
              if (s.isNotEmpty) onChanged(s.first);
            },
          ),
        ],
      ),
    );
  }
}

class _ToggleCard extends StatelessWidget {
  const _ToggleCard({
    required this.title,
    required this.icon,
    required this.value,
    required this.subtitle,
    required this.onChanged,
  });

  final String title;
  final IconData icon;
  final bool value;
  final String subtitle;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _DashCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Row(
        children: [
          Icon(icon, size: 22, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _DelayCard extends StatelessWidget {
  const _DelayCard({
    required this.google,
    required this.github,
    required this.onRefresh,
  });

  final int? google;
  final int? github;
  final VoidCallback onRefresh;

  String _fmt(int? ms) => ms == null ? '—' : '$ms ms';

  @override
  Widget build(BuildContext context) {
    return _DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('服务状态', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              IconButton(
                tooltip: '测速（经当前节点）',
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _kv(context, 'Google', _fmt(google)),
          const SizedBox(height: 6),
          _kv(context, 'GitHub', _fmt(github)),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    return Row(
      children: [
        Text(k, style: Theme.of(context).textTheme.bodyMedium),
        const Spacer(),
        Text(v, style: Theme.of(context).textTheme.titleSmall),
      ],
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.inuse, required this.source});

  final int? inuse;
  final String source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final has = inuse != null;
    return _DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('内存', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          Text(
            has ? formatBytes(inuse!) : '—',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          Text(
            has
                ? (source.isEmpty ? '内核堆' : source)
                : '内核未提供',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.connections,
    required this.totalSeen,
    required this.dnsActive,
    required this.live,
  });

  final int connections;
  final int totalSeen;
  final int dnsActive;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hint = live ? 'Clash API' : 'API 离线';
    return _DashCard(
      child: Row(
        children: [
          _stat(context, '活动连接', '$connections', live ? '实时' : hint),
          VerticalDivider(color: scheme.outlineVariant),
          _stat(context, '最近请求', '$totalSeen', '自启动累计'),
          VerticalDivider(color: scheme.outlineVariant),
          _stat(context, 'DNS 查询', '$dnsActive', '启动以来累计'),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value, String hint) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          Text(
            hint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
