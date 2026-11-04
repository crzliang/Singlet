/// Display helpers for profile cards (traffic / relative time).
class ProfileFormat {
  ProfileFormat._();

  static String bytes(int? n) {
    if (n == null) return '—';
    const kb = 1024.0;
    const mb = kb * 1024;
    const gb = mb * 1024;
    const tb = gb * 1024;
    final v = n.toDouble();
    if (v >= tb) return '${(v / tb).toStringAsFixed(1)}TB';
    if (v >= gb) return '${(v / gb).toStringAsFixed(1)}GB';
    if (v >= mb) return '${(v / mb).toStringAsFixed(1)}MB';
    if (v >= kb) return '${(v / kb).toStringAsFixed(0)}KB';
    return '${n}B';
  }

  static String trafficLine({int? used, int? total}) {
    if (used == null && total == null) return '—';
    if (total == null) return bytes(used);
    return '${bytes(used ?? 0)} / ${bytes(total)}';
  }

  static String relativeTime(DateTime? t, {DateTime? now}) {
    if (t == null) return '—';
    final n = now ?? DateTime.now();
    var diff = n.difference(t);
    if (diff.isNegative) diff = Duration.zero;
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 48) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    final y = t.year.toString().padLeft(4, '0');
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String expirePill(DateTime? t) {
    if (t == null) return '';
    final y = t.year.toString().padLeft(4, '0');
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
