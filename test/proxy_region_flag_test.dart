import 'package:flutter_test/flutter_test.dart';
import 'package:singlet/utils/proxy_region_flag.dart';

void main() {
  test('prefers embedded regional-indicator flag', () {
    expect(ProxyRegionFlag.flagFor('🇯🇵 Japan 03'), '🇯🇵');
    expect(ProxyRegionFlag.displayName('🇯🇵 Japan 03'), 'Japan 03');
  });

  test('maps english / code keywords', () {
    expect(ProxyRegionFlag.flagFor('____United_States_01'), '🇺🇸');
    expect(ProxyRegionFlag.flagFor('____Hong_Kong_03'), '🇭🇰');
    expect(ProxyRegionFlag.flagFor('____Japan_02'), '🇯🇵');
    expect(ProxyRegionFlag.flagFor('node-SG-01'), '🇸🇬');
  });

  test('maps cjk keywords', () {
    expect(ProxyRegionFlag.flagFor('香港 05'), '🇭🇰');
    expect(ProxyRegionFlag.flagFor('台湾节点'), '🇹🇼');
  });

  test('legacy underscore-only urltest label', () {
    expect(
      ProxyRegionFlag.displayName('_____2', type: 'URLTest'),
      '自动选择',
    );
    expect(
      ProxyRegionFlag.displayName('____', type: 'Selector'),
      '节点选择',
    );
  });
}
