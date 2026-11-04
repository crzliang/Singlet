import 'package:flutter_test/flutter_test.dart';
import 'package:singlet/services/app_settings.dart';
import 'package:singlet/services/dns_defaults.dart';
import 'package:singlet/services/route_defaults.dart';

void main() {
  test('injects private ip_is_private + cn rule-sets when enabled', () {
    final config = <String, dynamic>{
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'selector', 'tag': 'proxy', 'outbounds': ['direct']},
      ],
      'route': {'final': 'proxy'},
    };
    DnsDefaults.applyToConfig(config, proxyDetour: 'proxy');
    RouteDefaults.applyToConfig(
      config,
      proxyOutbound: 'proxy',
      route: const BypassRouteSettings(enabled: true, chinaDirect: true),
    );

    final route = config['route'] as Map;
    final sets = (route['rule_set'] as List).cast<Map>();
    expect(sets.any((e) => e['tag'] == RouteDefaults.geoipPrivateTag), isFalse);
    expect(sets.any((e) => e['tag'] == RouteDefaults.geositeCnTag), isTrue);
    expect(sets.any((e) => e['tag'] == RouteDefaults.geoipCnTag), isTrue);

    final rules = (route['rules'] as List).cast<Map>();
    expect(rules.any((e) => e['ip_is_private'] == true), isTrue);
    expect(
      rules.any((e) => e['rule_set'] == RouteDefaults.geositeCnTag),
      isTrue,
    );
    expect(config['experimental']['cache_file']['enabled'], isTrue);
  });

  test('strips injected rules when disabled', () {
    final config = <String, dynamic>{
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'direct'},
    };
    DnsDefaults.applyToConfig(config, proxyDetour: 'direct');
    RouteDefaults.applyToConfig(
      config,
      proxyOutbound: 'direct',
      route: const BypassRouteSettings(enabled: true, chinaDirect: true),
    );
    RouteDefaults.applyToConfig(
      config,
      proxyOutbound: 'direct',
      route: const BypassRouteSettings(enabled: false),
    );
    final route = config['route'] as Map;
    expect(route['rule_set'], isNull);
    final rules = (route['rules'] as List).cast<Map>();
    expect(rules.any((e) => e['ip_is_private'] == true), isFalse);
    expect(
      rules.any((e) => e['rule_set'] == RouteDefaults.geoipPrivateTag),
      isFalse,
    );
  });

  test('private falls back to ip_is_private without local srs', () {
    final config = <String, dynamic>{
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'selector', 'tag': 'proxy', 'outbounds': ['direct']},
      ],
      'route': {'final': 'proxy'},
    };
    DnsDefaults.applyToConfig(config, proxyDetour: 'proxy');
    RouteDefaults.applyToConfig(
      config,
      proxyOutbound: 'proxy',
      route: const BypassRouteSettings(
        enabled: true,
        privateDirect: true,
        chinaDirect: false,
      ),
    );
    final route = config['route'] as Map;
    expect(route['rule_set'], isNull);
    final rules = (route['rules'] as List).cast<Map>();
    expect(rules.any((e) => e['ip_is_private'] == true), isTrue);
  });

  test('private uses local geoip-private when path provided', () {
    final config = <String, dynamic>{
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'selector', 'tag': 'proxy', 'outbounds': ['direct']},
      ],
      'route': {'final': 'proxy'},
    };
    DnsDefaults.applyToConfig(config, proxyDetour: 'proxy');
    RouteDefaults.applyToConfig(
      config,
      proxyOutbound: 'proxy',
      route: const BypassRouteSettings(
        enabled: true,
        privateDirect: true,
        chinaDirect: false,
      ),
      localRuleSetPaths: {
        RouteDefaults.geoipPrivateTag: '/tmp/singlet-geoip-private.srs',
      },
    );
    final route = config['route'] as Map;
    final sets = (route['rule_set'] as List).cast<Map>();
    expect(
      sets.any(
        (e) =>
            e['tag'] == RouteDefaults.geoipPrivateTag &&
            e['type'] == 'local' &&
            e['path'] == '/tmp/singlet-geoip-private.srs',
      ),
      isTrue,
    );
    final rules = (route['rules'] as List).cast<Map>();
    expect(
      rules.any((e) => e['rule_set'] == RouteDefaults.geoipPrivateTag),
      isTrue,
    );
    expect(rules.any((e) => e['ip_is_private'] == true), isFalse);
  });

  test('process_name custom rule enables find_process', () {
    final config = <String, dynamic>{
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'selector', 'tag': 'proxy', 'outbounds': ['direct']},
      ],
      'route': {'final': 'proxy'},
    };
    DnsDefaults.applyToConfig(config, proxyDetour: 'proxy');
    RouteDefaults.applyToConfig(
      config,
      proxyOutbound: 'proxy',
      route: BypassRouteSettings(
        enabled: true,
        chinaDirect: false,
        customRules: [
          const CustomRouteRule(
            id: 'wx',
            match: CustomRuleMatch.processName,
            value: 'WeChat',
            outbound: CustomRuleOutbound.direct,
          ),
        ],
      ),
    );
    final route = config['route'] as Map;
    expect(route['find_process'], isTrue);
    final sets = (route['rule_set'] as List).cast<Map>();
    final inline = sets.firstWhere(
      (e) => '${e['tag']}'.startsWith(RouteDefaults.customTagPrefix),
    );
    expect(inline['type'], 'inline');
    expect(
      (inline['rules'] as List).first,
      {'process_name': ['WeChat']},
    );
  });

  test('custom rules keep list order ahead of cn', () {
    final config = <String, dynamic>{
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block', 'tag': 'block'},
        {'type': 'selector', 'tag': 'proxy', 'outbounds': ['direct']},
      ],
      'route': {'final': 'proxy'},
    };
    DnsDefaults.applyToConfig(config, proxyDetour: 'proxy');
    RouteDefaults.applyToConfig(
      config,
      proxyOutbound: 'proxy',
      route: BypassRouteSettings(
        enabled: true,
        chinaDirect: true,
        customRules: [
          const CustomRouteRule(
            id: '1',
            match: CustomRuleMatch.domainSuffix,
            value: 'openai.com',
            outbound: CustomRuleOutbound.proxy,
          ),
          const CustomRouteRule(
            id: '2',
            match: CustomRuleMatch.domainSuffix,
            value: 'baidu.com',
            outbound: CustomRuleOutbound.direct,
          ),
        ],
      ),
    );
    final route = config['route'] as Map;
    final sets = (route['rule_set'] as List).cast<Map>();
    expect(
      sets.any((e) => '${e['tag']}'.startsWith(RouteDefaults.customTagPrefix)),
      isTrue,
    );
    final rules = (route['rules'] as List).cast<Map>();
    final tags = [
      for (final r in rules)
        if (r['rule_set'] != null) '${r['rule_set']}',
    ];
    final customIdx = tags.indexWhere(
      (t) => t.startsWith(RouteDefaults.customTagPrefix),
    );
    final cnIdx = tags.indexOf(RouteDefaults.geositeCnTag);
    expect(customIdx, greaterThanOrEqualTo(0));
    expect(cnIdx, greaterThan(customIdx));
  });
}
