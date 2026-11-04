import 'dart:convert';

/// Parses common proxy share URIs into Clash-like proxy maps
/// (compatible with [SubscriptionService] Clash → sing-box mapping).
class ShareLinkParser {
  ShareLinkParser._();

  static bool looksLikeShareLink(String text) {
    final t = text.trim().toLowerCase();
    return t.startsWith('ss://') ||
        t.startsWith('vmess://') ||
        t.startsWith('vless://') ||
        t.startsWith('trojan://') ||
        t.startsWith('hysteria2://') ||
        t.startsWith('hy2://');
  }

  /// Returns a Clash-style proxy map, or null if unsupported / invalid.
  static Map<String, dynamic>? parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final lower = trimmed.toLowerCase();
    try {
      if (lower.startsWith('ss://')) return _parseSs(trimmed);
      if (lower.startsWith('vmess://')) return _parseVmess(trimmed);
      if (lower.startsWith('vless://')) return _parseVless(trimmed);
      if (lower.startsWith('trojan://')) return _parseTrojan(trimmed);
      if (lower.startsWith('hysteria2://') || lower.startsWith('hy2://')) {
        return _parseHysteria2(trimmed);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static Map<String, dynamic>? _parseSs(String raw) {
    final uriPart = raw.substring(5);
    final hash = uriPart.indexOf('#');
    var body = hash >= 0 ? uriPart.substring(0, hash) : uriPart;
    final name = hash >= 0
        ? Uri.decodeComponent(uriPart.substring(hash + 1))
        : 'ss';

    // SIP002: method:password@host:port (password may be url-encoded)
    if (body.contains('@')) {
      // Maybe whole userinfo is base64
      final at = body.lastIndexOf('@');
      final userinfo = body.substring(0, at);
      final hostPort = body.substring(at + 1);
      String method;
      String password;
      if (userinfo.contains(':')) {
        final colon = userinfo.indexOf(':');
        method = Uri.decodeComponent(userinfo.substring(0, colon));
        password = Uri.decodeComponent(userinfo.substring(colon + 1));
      } else {
        final decoded = _decodeBase64(userinfo);
        if (decoded == null || !decoded.contains(':')) return null;
        final colon = decoded.indexOf(':');
        method = decoded.substring(0, colon);
        password = decoded.substring(colon + 1);
      }
      final hp = _splitHostPort(hostPort);
      if (hp == null) return null;
      return {
        'name': name.isEmpty ? 'ss' : name,
        'type': 'ss',
        'server': hp.$1,
        'port': hp.$2,
        'cipher': method,
        'password': password,
      };
    }

    // Legacy: base64(method:password@host:port)
    final decoded = _decodeBase64(body);
    if (decoded == null) return null;
    final at = decoded.lastIndexOf('@');
    if (at < 0) return null;
    final userinfo = decoded.substring(0, at);
    final hostPort = decoded.substring(at + 1);
    final colon = userinfo.indexOf(':');
    if (colon < 0) return null;
    final hp = _splitHostPort(hostPort);
    if (hp == null) return null;
    return {
      'name': name.isEmpty ? 'ss' : name,
      'type': 'ss',
      'server': hp.$1,
      'port': hp.$2,
      'cipher': userinfo.substring(0, colon),
      'password': userinfo.substring(colon + 1),
    };
  }

  static Map<String, dynamic>? _parseVmess(String raw) {
    final b64 = raw.substring(8).trim();
    final decoded = _decodeBase64(b64);
    if (decoded == null) return null;
    final obj = jsonDecode(decoded);
    if (obj is! Map) return null;
    final m = Map<String, dynamic>.from(obj);
    final port = _asInt(m['port']);
    if (port == null) return null;
    final out = <String, dynamic>{
      'name': '${m['ps'] ?? m['name'] ?? 'vmess'}',
      'type': 'vmess',
      'server': '${m['add'] ?? m['host'] ?? ''}',
      'port': port,
      'uuid': '${m['id'] ?? ''}',
      'alterId': _asInt(m['aid']) ?? 0,
      'cipher': '${m['scy'] ?? m['security'] ?? 'auto'}',
      'network': '${m['net'] ?? 'tcp'}',
    };
    if (out['server'] == '' || out['uuid'] == '') return null;
    final tls = '${m['tls'] ?? ''}';
    if (tls == 'tls' || tls == 'true') out['tls'] = true;
    final sni = m['sni'] ?? m['host'];
    if (sni != null && '$sni'.isNotEmpty) out['servername'] = '$sni';
    final path = m['path'];
    if (path != null && '$path'.isNotEmpty) {
      out['ws-opts'] = {'path': '$path'};
      if (m['host'] != null) {
        out['ws-opts'] = {
          'path': '$path',
          'headers': {'Host': '${m['host']}'},
        };
      }
    }
    final fp = m['fp'];
    if (fp != null && '$fp'.isNotEmpty) {
      out['client-fingerprint'] = '$fp';
    }
    return out;
  }

  static Map<String, dynamic>? _parseVless(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.userInfo.isEmpty || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : 443;
    final q = uri.queryParameters;
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : 'vless';
    final out = <String, dynamic>{
      'name': name,
      'type': 'vless',
      'server': uri.host,
      'port': port,
      'uuid': Uri.decodeComponent(uri.userInfo),
      'network': q['type'] ?? q['net'] ?? 'tcp',
    };
    final flow = q['flow'];
    if (flow != null && flow.isNotEmpty) out['flow'] = flow;
    final security = (q['security'] ?? '').toLowerCase();
    if (security == 'tls' || security == 'reality') {
      out['tls'] = true;
    }
    final sni = q['sni'] ?? q['servername'] ?? q['host'];
    if (sni != null && sni.isNotEmpty) out['servername'] = sni;
    final fp = q['fp'];
    if (fp != null && fp.isNotEmpty) out['client-fingerprint'] = fp;
    if (security == 'reality') {
      out['reality-opts'] = {
        'public-key': q['pbk'] ?? '',
        'short-id': q['sid'] ?? '',
      };
    }
    final network = '${out['network']}'.toLowerCase();
    if (network == 'ws') {
      out['ws-opts'] = {
        'path': q['path'] ?? '/',
        if ((q['host'] ?? '').isNotEmpty) 'headers': {'Host': q['host']},
      };
    } else if (network == 'grpc') {
      out['grpc-opts'] = {
        'grpc-service-name': q['serviceName'] ?? q['service_name'] ?? '',
      };
    }
    final alpn = q['alpn'];
    if (alpn != null && alpn.isNotEmpty) {
      out['alpn'] = alpn.split(',');
    }
    final pe = q['packetEncoding'] ?? q['packet-encoding'];
    if (pe != null && pe.isNotEmpty) out['packet-encoding'] = pe;
    return out;
  }

  static Map<String, dynamic>? _parseTrojan(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.userInfo.isEmpty || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : 443;
    final q = uri.queryParameters;
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : 'trojan';
    final out = <String, dynamic>{
      'name': name,
      'type': 'trojan',
      'server': uri.host,
      'port': port,
      'password': Uri.decodeComponent(uri.userInfo),
      'network': q['type'] ?? 'tcp',
      'tls': true,
    };
    final sni = q['sni'] ?? q['peer'];
    if (sni != null && sni.isNotEmpty) out['servername'] = sni;
    if (q['allowInsecure'] == '1' || q['allowInsecure'] == 'true') {
      out['skip-cert-verify'] = true;
    }
    final network = '${out['network']}'.toLowerCase();
    if (network == 'ws') {
      out['ws-opts'] = {
        'path': q['path'] ?? '/',
        if ((q['host'] ?? '').isNotEmpty) 'headers': {'Host': q['host']},
      };
    } else if (network == 'grpc') {
      out['grpc-opts'] = {
        'grpc-service-name': q['serviceName'] ?? '',
      };
    }
    final fp = q['fp'];
    if (fp != null && fp.isNotEmpty) out['client-fingerprint'] = fp;
    return out;
  }

  static Map<String, dynamic>? _parseHysteria2(String raw) {
    final normalized = raw.toLowerCase().startsWith('hy2://')
        ? 'hysteria2://${raw.substring(6)}'
        : raw;
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : 443;
    final q = uri.queryParameters;
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : 'hysteria2';
    final out = <String, dynamic>{
      'name': name,
      'type': 'hysteria2',
      'server': uri.host,
      'port': port,
      if (uri.userInfo.isNotEmpty)
        'password': Uri.decodeComponent(uri.userInfo),
    };
    final sniVal = q['sni'] ?? q['peer'];
    if (sniVal != null && sniVal.isNotEmpty) out['servername'] = sniVal;
    if (q['insecure'] == '1' || q['insecure'] == 'true') {
      out['skip-cert-verify'] = true;
    }
    final obfs = q['obfs'];
    if (obfs != null && obfs.isNotEmpty) {
      out['obfs'] = obfs;
      final op = q['obfs-password'] ?? q['obfsPassword'];
      if (op != null) out['obfs-password'] = op;
    }
    return out;
  }

  static (String, int)? _splitHostPort(String hostPort) {
    var s = hostPort.trim();
    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      if (end < 0) return null;
      final host = s.substring(1, end);
      final rest = s.substring(end + 1);
      if (!rest.startsWith(':')) return null;
      final port = int.tryParse(rest.substring(1));
      if (port == null) return null;
      return (host, port);
    }
    final colon = s.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(s.substring(colon + 1));
    if (port == null) return null;
    return (s.substring(0, colon), port);
  }

  static String? _decodeBase64(String input) {
    var s = input.trim().replaceAll('-', '+').replaceAll('_', '/');
    s = s.replaceAll(RegExp(r'\s'), '');
    final mod = s.length % 4;
    if (mod > 0) s = s.padRight(s.length + (4 - mod), '=');
    try {
      return utf8.decode(base64.decode(s), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }
}
