import 'dart:async';

import 'package:flutter/material.dart';

import '../services/clash_api_client.dart';
import '../utils/display_tags.dart';
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

  /// Column index matching [DataTable.columns] (null = API order).
  int? _sortColumnIndex;
  bool _sortAscending = false;

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

  void _onSort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _sortAscending = ascending;
    });
  }

  List<ClashConnectionRow> get _filtered {
    final q = _query.trim().toLowerCase();
    final base = q.isEmpty
        ? List<ClashConnectionRow>.from(_rows)
        : _rows.where((r) {
            final rule = DisplayTags.sanitize(r.rule).toLowerCase();
            final outbound =
                DisplayTags.sanitize(r.outbound).toLowerCase();
            return r.process.toLowerCase().contains(q) ||
                r.target.toLowerCase().contains(q) ||
                rule.contains(q) ||
                r.rule.toLowerCase().contains(q) ||
                outbound.contains(q) ||
                r.outbound.toLowerCase().contains(q);
          }).toList();

    final col = _sortColumnIndex;
    if (col == null) return base;

    int cmp(ClashConnectionRow a, ClashConnectionRow b) {
      switch (col) {
        case 0:
          return a.process.toLowerCase().compareTo(b.process.toLowerCase());
        case 1:
          return a.target.toLowerCase().compareTo(b.target.toLowerCase());
        case 2:
          return DisplayTags.sanitize(a.rule)
              .toLowerCase()
              .compareTo(DisplayTags.sanitize(b.rule).toLowerCase());
        case 3:
          return DisplayTags.sanitize(
            ProxyRegionFlag.displayName(a.outbound),
          ).toLowerCase().compareTo(
                DisplayTags.sanitize(
                  ProxyRegionFlag.displayName(b.outbound),
                ).toLowerCase(),
              );
        case 4:
          return a.downloadSpeed.compareTo(b.downloadSpeed);
        case 5:
          return a.uploadSpeed.compareTo(b.uploadSpeed);
        case 6:
          return a.download.compareTo(b.download);
        case 7:
          return a.upload.compareTo(b.upload);
        default:
          return 0;
      }
    }

    base.sort((a, b) {
      final r = cmp(a, b);
      return _sortAscending ? r : -r;
    });
    return base;
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
                                      sortColumnIndex: _sortColumnIndex,
                                      sortAscending: _sortAscending,
                                      columns: [
                                        DataColumn(
                                          label: const Text('进程'),
                                          onSort: _onSort,
                                        ),
                                        DataColumn(
                                          label: const Text('目标'),
                                          onSort: _onSort,
                                        ),
                                        DataColumn(
                                          label: const Text('规则'),
                                          onSort: _onSort,
                                        ),
                                        DataColumn(
                                          label: const Text('出口'),
                                          onSort: _onSort,
                                        ),
                                        DataColumn(
                                          label: const Text('下载'),
                                          numeric: true,
                                          onSort: _onSort,
                                        ),
                                        DataColumn(
                                          label: const Text('上传'),
                                          numeric: true,
                                          onSort: _onSort,
                                        ),
                                        DataColumn(
                                          label: const Text('下载总量'),
                                          numeric: true,
                                          onSort: _onSort,
                                        ),
                                        DataColumn(
                                          label: const Text('上传总量'),
                                          numeric: true,
                                          onSort: _onSort,
                                        ),
                                        const DataColumn(label: Text('')),
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
    final outboundLabel = DisplayTags.sanitize(
      ProxyRegionFlag.displayName(r.outbound),
    );
    final ruleLabel = r.rule.isEmpty ? '—' : DisplayTags.sanitize(r.rule);
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
        DataCell(Text(ruleLabel)),
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
