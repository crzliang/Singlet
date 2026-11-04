import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// MethodChannel for privileged helper install / TUN control.
///
/// Channel: `com.singlet/helper`
class HelperChannel {
  HelperChannel({
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('com.singlet/helper');

  final MethodChannel _channel;

  Future<bool> isInstalled() async {
    try {
      final installed =
          await _channel.invokeMethod<bool>('isInstalled') ?? false;
      if (installed) return true;
      // Fallback only when path probe fails — keep timeout short via native ping.
      return await tunPing();
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<String> statusText() async {
    try {
      return await _channel.invokeMethod<String>('status') ?? 'unknown';
    } on MissingPluginException {
      return 'stub-no-plugin';
    }
  }

  /// Triggers admin install. Throws [HelperInstallException] on failure/cancel.
  Future<HelperInstallResult> install() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('install');
      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        return HelperInstallResult(
          ok: map['ok'] == true,
          message: '${map['message'] ?? 'done'}',
          installed: map['installed'] == true,
          running: map['running'] == true,
          path: map['path']?.toString(),
        );
      }
      final ok = raw == true;
      return HelperInstallResult(
        ok: ok,
        message: ok ? '安装成功' : '安装失败（未知返回）',
        installed: ok,
        running: false,
      );
    } on MissingPluginException {
      throw HelperInstallException(
        'missing_plugin',
        '当前平台无 Helper 插件（仅 macOS）',
      );
    } on PlatformException catch (e) {
      debugPrint('helper install: $e');
      throw HelperInstallException(e.code, e.message ?? e.code);
    }
  }

  Future<bool> tunPing() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('tunPing');
      return raw is Map && raw['ok'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<TunHelperStatus> tunStatus() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('tunStatus');
      if (raw is Map) {
        final m = Map<String, dynamic>.from(raw);
        return TunHelperStatus(
          reachable: m['ok'] == true,
          running: m['running'] == true,
          version: m['version']?.toString(),
          inuse: _asInt(m['inuse']),
          oslimit: _asInt(m['oslimit']),
        );
      }
    } on MissingPluginException {
      // ignore
    } on PlatformException catch (e) {
      return TunHelperStatus(reachable: false, error: e.message);
    }
    return const TunHelperStatus(reachable: false);
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  Future<void> tunStart({
    required String configPath,
    String clashApiBaseUrl = 'http://127.0.0.1:9090',
    int httpPort = 7890,
    int apiPort = 9090,
  }) async {
    try {
      await _channel.invokeMethod<void>('tunStart', {
        'configPath': configPath,
        'clashApiBaseUrl': clashApiBaseUrl,
        'httpPort': httpPort,
        'apiPort': apiPort,
      });
    } on MissingPluginException {
      throw HelperInstallException('missing_plugin', '仅 macOS 支持 TUN');
    } on PlatformException catch (e) {
      throw HelperInstallException(e.code, e.message ?? e.code);
    }
  }

  Future<void> tunStop() async {
    try {
      await _channel.invokeMethod<void>('tunStop');
    } on MissingPluginException {
      // no-op
    } on PlatformException catch (e) {
      throw HelperInstallException(e.code, e.message ?? e.code);
    }
  }
}

class TunHelperStatus {
  const TunHelperStatus({
    required this.reachable,
    this.running = false,
    this.version,
    this.error,
    this.inuse,
    this.oslimit,
  });

  final bool reachable;
  final bool running;
  final String? version;
  final String? error;
  final int? inuse;
  final int? oslimit;
}

class HelperInstallResult {
  const HelperInstallResult({
    required this.ok,
    required this.message,
    required this.installed,
    required this.running,
    this.path,
  });

  final bool ok;
  final String message;
  final bool installed;
  final bool running;
  final String? path;
}

class HelperInstallException implements Exception {
  HelperInstallException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '[$code] $message';
}
