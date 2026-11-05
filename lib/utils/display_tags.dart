/// Strip internal tag prefixes from user-visible labels.
///
/// Engine tags stay `singlet-geosite-cn` etc.; the UI shows `geosite-cn`.
class DisplayTags {
  DisplayTags._();

  static final _prefix = RegExp(r'\b(?:singlet|sbg)-', caseSensitive: false);

  /// Remove `singlet-` / `sbg-` prefixes anywhere in a display string.
  static String sanitize(String raw) {
    if (raw.isEmpty) return raw;
    return raw.replaceAll(_prefix, '');
  }
}
