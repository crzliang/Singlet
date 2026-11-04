/// Region flag helpers for Clash-style proxy display names.
///
/// Priority:
/// 1. Regional-indicator flag emoji already in the name (🇭🇰 / 🇯🇵 …)
/// 2. Common region keywords / codes → flag emoji
class ProxyRegionFlag {
  ProxyRegionFlag._();

  static final _flagEmoji = RegExp(
    r'[\u{1F1E6}-\u{1F1FF}]{2}',
    unicode: true,
  );

  /// Longer / more specific keys first to avoid partial clashes.
  static const _keywordFlags = <(List<String>, String)>[
    (['hong kong', 'hong_kong', 'hongkong', '香港', 'hk'], '🇭🇰'),
    (['taiwan', '台湾', '台灣', 'tw'], '🇹🇼'),
    (['united states', 'united_states', 'usa', '美国', '美國', 'us'], '🇺🇸'),
    (['united kingdom', 'united_kingdom', 'britain', '英国', '英國', 'uk', 'gb'],
        '🇬🇧'),
    (['singapore', '新加坡', 'sg'], '🇸🇬'),
    (['japan', '日本', 'jp'], '🇯🇵'),
    (['korea', '韩国', '韓國', 'kr'], '🇰🇷'),
    (['germany', '德国', '德國', 'de'], '🇩🇪'),
    (['netherlands', '荷兰', '荷蘭', 'nl'], '🇳🇱'),
    (['malaysia', '马来', '馬來', 'my'], '🇲🇾'),
    (['france', '法国', '法國', 'fr'], '🇫🇷'),
    (['canada', '加拿大', 'ca'], '🇨🇦'),
    (['australia', '澳大利亚', '澳洲', 'au'], '🇦🇺'),
    (['turkey', '土耳其', 'tr'], '🇹🇷'),
    (['russia', '俄罗斯', '俄羅斯', 'ru'], '🇷🇺'),
    (['india', '印度', 'in'], '🇮🇳'),
    (['philippines', '菲律宾', '菲律賓', 'ph'], '🇵🇭'),
    (['thailand', '泰国', '泰國', 'th'], '🇹🇭'),
    (['vietnam', '越南', 'vn'], '🇻🇳'),
    (['indonesia', '印尼', 'id'], '🇮🇩'),
    (['macao', 'macau', '澳门', '澳門', 'mo'], '🇲🇴'),
    (['china', '中国', '大陸', '大陆', 'cn'], '🇨🇳'),
  ];

  /// Extract a display flag emoji, or null if unknown.
  static String? flagFor(String name) {
    final embedded = _flagEmoji.firstMatch(name)?.group(0);
    if (embedded != null) return embedded;

    final normalized = name.toLowerCase().replaceAll('-', '_');
    for (final (keys, flag) in _keywordFlags) {
      for (final key in keys) {
        if (_keywordHits(normalized, name, key)) return flag;
      }
    }
    return null;
  }

  /// Name for the card title: drop leading flag emoji / underscore noise.
  static String displayName(String name, {String? type}) {
    var s = name;
    final flag = _flagEmoji.firstMatch(s);
    if (flag != null && flag.start == 0) {
      s = s.substring(flag.end).trimLeft();
    }
    s = s.replaceFirst(RegExp(r'^[\s_]+'), '');
    s = s.replaceFirst(RegExp(r'[\s_]+$'), '');

    // Legacy drafts: CJK/emoji were wiped to underscores by _safeTag.
    if (s.isEmpty || RegExp(r'^_+\d*$').hasMatch(name)) {
      final t = (type ?? '').toLowerCase();
      if (t == 'urltest') return '自动选择';
      if (t == 'selector') return '节点选择';
      if (t == 'fallback') return '故障转移';
      if (t == 'loadbalance') return '负载均衡';
      if (t == 'direct') return 'DIRECT';
      if (t == 'reject') return 'REJECT';
    }
    return s.isEmpty ? name : s;
  }

  static bool _keywordHits(String normalized, String original, String key) {
    final k = key.toLowerCase();
    // CJK / multi-word: substring ok.
    if (k.contains(' ') || _hasCjk(k)) {
      return original.contains(key) || normalized.contains(k.replaceAll(' ', '_'));
    }
    // Short latin codes: token boundary (avoid "us" in "australia").
    if (k.length <= 3) {
      return RegExp(
        '(^|[^a-z0-9])${RegExp.escape(k)}([^a-z0-9]|\$)',
        caseSensitive: false,
      ).hasMatch(normalized);
    }
    return normalized.contains(k);
  }

  static bool _hasCjk(String s) =>
      s.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);
}
