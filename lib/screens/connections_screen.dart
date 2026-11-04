import 'dart:async';

import 'package:flutter/material.dart';

import '../services/clash_api_client.dart';
import '../utils/proxy_region_flag.dart';

/// Clash Verge–style「实时连接」table (Material 3).
class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key, required this.clashApi});

  final ClashApiClient clashApi;

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  Timer? _poll;
  bool _loading = true;
  bool _reachable = false;
  String _query = '';
  List<ClashConnectionRow> _rows = const [];

  @override
  void initState() {
    super.initState();
    _reload();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _reload());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final list = await widget.clashApi.fetchConnectionList();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _reachable = list.reachable;
      _rows = list.rows;
    });
  }

  List<ClashConnectionRow> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows.where((r) {
      return r.process.toLowerCase().contains(q) ||
          r.target.toLowerCase().contains(q) ||
          r.rule.toLowerCase().contains(q) ||
          r.outbound.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _closeOne(ClashConnectionRow row) async {
    final ok = await widget.clashApi.closeConnection(row.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('关闭连接失败')),
      );
    }
    await _reload();
  }

  Future<void> _closeAll() async {
    final ok = await widget.clashApi.closeAllConnections();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已清空连接' : '清空失败')),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filtered = _filtered;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '实时连接',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(width: 12),
              if (!_reachable)
                Text(
                  'API 不可用',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                )
              else
                Text(
                  '${filtered.length} 条',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              const Spacer(),
              SizedBox(
                width: 220,
                child: TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索进程 / 目标',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '清空全部连接',
                onPressed: _rows.isEmpty ? null : _closeAll,
                icon: Badge(
                  isLabelVisible: _rows.isNotEmpty,
                  label: Text('${_rows.length}'),
                  child: const Icon(Icons.delete_outline),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: _loading && _rows.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : filtered.isEmpty
                      ? Center(
                          child: Text(
                            _reachable ? '暂无连接' : '无法读取连接（内核未开或 Clash API 不可达）',
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                          ),
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minWidth: constraints.maxWidth,
                                  ),
                                  child: SingleChildScrollView(
                                    child: DataTable(
                                      headingRowHeight: 44,
                                      dataRowMinHeight: 44,
                                      dataRowMaxHeight: 56,
                                      columnSpacing: 20,
                                      horizontalMargin: 16,
                                      columns: const [
                                        DataColumn(label: Text('进程')),
                                        DataColumn(label: Text('目标')),
                                        DataColumn(label: Text('规则')),
                                        DataColumn(label: Text('出口')),
                                        DataColumn(
                                          label: Text('下载'),
                                          numeric: true,
                                        ),
                                        DataColumn(
                                          label: Text('上传'),
                                          numeric: true,
                                        ),
                                        DataColumn(
                                          label: Text('下载总量'),
                                          numeric: true,
                                        ),
                                        DataColumn(
                                          label: Text('上传总量'),
                                          numeric: true,
                                        ),
                                        DataColumn(label: Text('')),
                                      ],
                                      rows: [
                                        for (var i = 0; i < filtered.length; i++)
                                          _row(context, filtered[i], i.isOdd),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
            ),
          ),
        ],
      ),
    );
  }

  DataRow _row(BuildContext context, ClashConnectionRow r, bool odd) {
    final scheme = Theme.of(context).colorScheme;
    final flag = ProxyRegionFlag.flagFor(r.outbound) ?? '';
    final outboundLabel = ProxyRegionFlag.displayName(r.outbound);
    return DataRow(
      color: WidgetStatePropertyAll(
        odd ? scheme.surfaceContainerLow.withValues(alpha: 0.45) : null,
      ),
      cells: [
        DataCell(
          SizedBox(
            width: 100,
            child: Text(
              r.process,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DataCell(
          SizedBox(
            width: 220,
            child: Text(
              r.target,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DataCell(Text(r.rule.isEmpty ? '—' : r.rule)),
        DataCell(
          SizedBox(
            width: 160,
            child: Row(
              children: [
                if (flag.isNotEmpty) ...[
                  Text(flag, style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    outboundLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        DataCell(Text(formatSpeed(r.downloadSpeed))),
        DataCell(Text(formatSpeed(r.uploadSpeed))),
        DataCell(Text(formatBytes(r.download))),
        DataCell(Text(formatBytes(r.upload))),
        DataCell(
          IconButton(
            tooltip: '关闭连接',
            icon: Icon(Icons.block, size: 18, color: scheme.error),
            onPressed: () => _closeOne(r),
          ),
        ),
      ],
    );
  }
}
