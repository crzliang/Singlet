import 'package:flutter_test/flutter_test.dart';
import 'package:singlet/services/app_settings.dart';
import 'package:singlet/services/dns_defaults.dart';

void main() {
  test('intranet suffixes and bare hostnames use lan-dns', () {
    final dns = DnsDefaults.buildDns(
      proxyDetour: 'proxy',
      dns: const DnsSettings(
        localAddresses: ['192.168.100.1', '223.5.5.5'],
        remoteAddresses: ['https://1.1.1.1/dns-query'],
        strategy: DnsQueryStrategy.roundRobin,
        intranetSuffixes: ['local', '.corp.example'],
      ),
    );

    final servers = (dns['servers'] as List).cast<Map>();
    expect(servers.any((e) => e['tag'] == DnsDefaults.lanTag), isTrue);
    final lan = servers.firstWhere((e) => e['tag'] == DnsDefaults.lanTag);
    // Only the private resolver — not public 223.5.5.5.
    expect(lan['type'], 'udp');
    expect(lan['server'], '192.168.100.1');

    final rules = (dns['rules'] as List).cast<Map>();
    expect(rules.first['server'], DnsDefaults.lanTag);
    expect(
      (rules.first['domain_suffix'] as List).map((e) => '$e').toList(),
      containsAll(['local', 'corp.example']),
    );
    expect(
      rules.any(
        (e) =>
            e['server'] == DnsDefaults.lanTag &&
            (e['domain_regex'] as List?)?.contains(r'^[^.]+$') == true,
      ),
      isTrue,
    );
    expect(dns['final'], DnsDefaults.remoteTag);
  });

  test('without private local DNS, intranet falls back to local-dns', () {
    final dns = DnsDefaults.buildDns(
      proxyDetour: 'proxy',
      dns: const DnsSettings(
        localAddresses: ['223.5.5.5'],
        remoteAddresses: ['https://1.1.1.1/dns-query'],
        intranetSuffixes: ['lan'],
      ),
    );
    final rules = (dns['rules'] as List).cast<Map>();
    expect(rules.first['server'], DnsDefaults.localTag);
    expect(
      (dns['servers'] as List).cast<Map>().any(
            (e) => e['tag'] == DnsDefaults.lanTag,
          ),
      isFalse,
    );
  });
}
