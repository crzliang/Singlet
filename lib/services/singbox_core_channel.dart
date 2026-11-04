import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// MethodChannel bridge to macOS native → Go c-shared.
///
/// Channel: `com.singlet/singbox_core`
class SingboxCoreChannel {
  SingboxCoreChannel({
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('com.singlet/singbox_core');

  final MethodChannel _channel;

  Future<String> version() async {
    try {
      return await _channel.invokeMethod<String>('version') ?? 'unknown';
    } on MissingPluginException {
      return 'stub-no-plugin';
    } on PlatformException catch (e) {
      debugPrint('singbox version: $e');
      return 'error:${e.code}';
    }
  }

  Future<bool> isRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<Map<String, dynamic>> status() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('status');
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
      return {'raw': raw};
    } on MissingPluginException {
      return {'stub': true, 'running': false};
    }
  }

  /// Go runtime MemStats via dylib (`inuse` / `oslimit`). Empty if unavailable.
  Future<Map<String, dynamic>> memory() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('memory');
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
    return const {};
  }

  /// Start embedded core with a sing-box JSON config path and Clash API URL.
  /// Always reloads: if already running, native side stops then starts with [configPath].
  Future<void> start({
    required String configPath,
    String clashApiBaseUrl = 'http://127.0.0.1:9090',
    bool force = true,
  }) async {
    try {
      await _channel.invokeMethod<void>('start', {
        'configPath': configPath,
        'clashApiBaseUrl': clashApiBaseUrl,
        'force': force,
      });
    } on MissingPluginException {
      // UI-only / non-macOS: no-op
    } on PlatformException catch (e) {
      throw SingboxCoreException(e.message ?? e.code);
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // no-op
    } on PlatformException catch (e) {
      throw SingboxCoreException(e.message ?? e.code);
    }
  }

  /// Stop (if needed) and start with [configPath].
  Future<void> applyConfig(String configPath) async {
    await start(
      configPath: configPath,
      clashApiBaseUrl: 'http://127.0.0.1:9090',
      force: true,
    );
  }
}

class SingboxCoreException implements Exception {
  SingboxCoreException(this.message);
  final String message;
  @override
  String toString() => message;
}
