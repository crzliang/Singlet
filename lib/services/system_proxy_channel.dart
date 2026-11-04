import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// MethodChannel: `com.singlet/system_proxy`
class SystemProxyChannel {
  SystemProxyChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.singlet/system_proxy');

  final MethodChannel _channel;

  Future<SystemProxyStatus> status() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('status');
      if (raw is Map) {
        final m = Map<String, dynamic>.from(raw);
        return SystemProxyStatus(
          managed: m['managed'] == true,
          anyProxyOn: m['anyProxyOn'] == true,
        );
      }
    } on MissingPluginException {
      // non-macOS
    } on PlatformException catch (e) {
      debugPrint('system_proxy status: $e');
    }
    return const SystemProxyStatus();
  }

  Future<void> enable({
    String host = '127.0.0.1',
    int httpPort = 7890,
    int? socksPort,
  }) async {
    try {
      await _channel.invokeMethod<void>('enable', {
        'host': host,
        'httpPort': httpPort,
        'socksPort': socksPort ?? httpPort,
      });
    } on MissingPluginException {
      throw SystemProxyException('missing_plugin', '仅 macOS 支持系统代理');
    } on PlatformException catch (e) {
      throw SystemProxyException(e.code, e.message ?? e.code);
    }
  }

  Future<void> disable() async {
    try {
      await _channel.invokeMethod<void>('disable');
    } on MissingPluginException {
      // no-op
    } on PlatformException catch (e) {
      throw SystemProxyException(e.code, e.message ?? e.code);
    }
  }

  /// Point system DNS at TUN peer addresses so queries enter hijack-dns.
  Future<void> enableTunDns({required List<String> servers}) async {
    try {
      await _channel.invokeMethod<void>('enableTunDns', {
        'servers': servers,
      });
    } on MissingPluginException {
      throw SystemProxyException('missing_plugin', '仅 macOS 支持 TUN DNS');
    } on PlatformException catch (e) {
      throw SystemProxyException(e.code, e.message ?? e.code);
    }
  }

  /// Restore previous DNS / DHCP.
  Future<void> disableTunDns() async {
    try {
      await _channel.invokeMethod<void>('disableTunDns');
    } on MissingPluginException {
      // no-op
    } on PlatformException catch (e) {
      throw SystemProxyException(e.code, e.message ?? e.code);
    }
  }
}

class SystemProxyStatus {
  const SystemProxyStatus({
    this.managed = false,
    this.anyProxyOn = false,
  });

  final bool managed;
  final bool anyProxyOn;
}

class SystemProxyException implements Exception {
  SystemProxyException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '[$code] $message';
}
