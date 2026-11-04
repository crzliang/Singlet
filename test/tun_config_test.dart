import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singlet/services/tun_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('writeTunVariant injects tun inbound and keeps mixed', () async {
    final dir = await Directory.systemTemp.createTemp('singlet_tun_');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}/base.json');
    await src.writeAsString(jsonEncode({
      'inbounds': [
        {
          'type': 'mixed',
          'tag': 'mixed-in',
          'listen': '127.0.0.1',
          'listen_port': 7890,
        }
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'}
      ],
      'route': {'final': 'direct'},
      '_singlet_meta': {'x': 1},
    }));

    final out = await TunConfig.writeTunVariant(src.path);
    final map = jsonDecode(await File(out).readAsString()) as Map;
    expect(map.containsKey('_singlet_meta'), isFalse);
    final inbounds = map['inbounds'] as List;
    expect(inbounds.any((e) => e['type'] == 'tun'), isTrue);
    expect(inbounds.any((e) => e['type'] == 'mixed'), isTrue);
    final tun = inbounds.cast<Map>().firstWhere((e) => e['type'] == 'tun');
    final address = (tun['address'] as List).map((e) => '$e').toList();
    expect(address, contains(TunConfig.tunInet4));
    expect(address, isNot(contains(TunConfig.tunInet6)));
    expect(TunConfig.tunDnsServers, contains(TunConfig.tunDnsPeer));
    expect(tun['stack'], 'mixed');
    expect(map['route']['auto_detect_interface'], isTrue);
    expect(await TunConfig.mixedPortFromConfig(src.path), 7890);
  });
}
