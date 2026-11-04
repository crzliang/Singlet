import 'package:flutter_test/flutter_test.dart';
import 'package:singlet/services/share_link_parser.dart';

void main() {
  test('parses ss SIP002', () {
    final p = ShareLinkParser.parse(
      'ss://aes-256-gcm:password@example.com:8388#node',
    );
    expect(p, isNotNull);
    expect(p!['type'], 'ss');
    expect(p['server'], 'example.com');
    expect(p['port'], 8388);
    expect(p['cipher'], 'aes-256-gcm');
    expect(p['password'], 'password');
    expect(p['name'], 'node');
  });

  test('parses vless reality', () {
    final p = ShareLinkParser.parse(
      'vless://123e4567-e89b-12d3-a456-426614174000@1.2.3.4:443'
      '?encryption=none&flow=xtls-rprx-vision&security=reality'
      '&sni=www.example.com&fp=chrome&pbk=abc&sid=dead'
      '&type=tcp#Reality',
    );
    expect(p, isNotNull);
    expect(p!['type'], 'vless');
    expect(p['server'], '1.2.3.4');
    expect(p['port'], 443);
    expect(p['flow'], 'xtls-rprx-vision');
    expect(p['tls'], true);
    expect(p['reality-opts']['public-key'], 'abc');
    expect(p['name'], 'Reality');
  });

  test('parses trojan', () {
    final p = ShareLinkParser.parse(
      'trojan://secret@host.example:443?sni=host.example#t1',
    );
    expect(p, isNotNull);
    expect(p!['type'], 'trojan');
    expect(p['password'], 'secret');
    expect(p['servername'], 'host.example');
  });
}
