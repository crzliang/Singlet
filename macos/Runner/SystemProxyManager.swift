import Foundation

/// Sets / clears macOS per-service HTTP(S)/SOCKS proxies via `networksetup`.
/// Also manages TUN DNS (point system resolver at TUN peer addresses).
enum SystemProxyManager {
  private static let backupKey = "com.singlet.systemProxy.backup"
  private static let managedKey = "com.singlet.systemProxy.managed"
  private static let dnsBackupKey = "com.singlet.systemDns.backup"
  private static let dnsManagedKey = "com.singlet.systemDns.managed"

  struct ServiceSnapshot: Codable {
    var name: String
    var webEnabled: Bool
    var webHost: String
    var webPort: Int
    var secureEnabled: Bool
    var secureHost: String
    var securePort: Int
    var socksEnabled: Bool
    var socksHost: String
    var socksPort: Int
  }

  struct DnsSnapshot: Codable {
    var name: String
    /// Empty means DHCP / "Empty" for networksetup -setdnsservers.
    var servers: [String]
  }

  static func isManagedEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: managedKey)
  }

  static func status() -> [String: Any] {
    let services = listServices()
    var anyOn = false
    for s in services {
      if proxyEnabled(service: s, flag: "-getwebproxy") ||
        proxyEnabled(service: s, flag: "-getsecurewebproxy") ||
        proxyEnabled(service: s, flag: "-getsocksfirewallproxy")
      {
        anyOn = true
        break
      }
    }
    return [
      "managed": isManagedEnabled(),
      "anyProxyOn": anyOn,
      "services": services,
    ]
  }

  /// Point active services at host:httpPort (HTTP/HTTPS) and host:socksPort (SOCKS).
  static func enable(host: String, httpPort: Int, socksPort: Int) throws {
    let services = listServices()
    if services.isEmpty {
      throw ProxyError.message("未找到可用网络服务")
    }
    if !isManagedEnabled() {
      let snaps = services.map { snapshot(service: $0) }
      if let data = try? JSONEncoder().encode(snaps) {
        UserDefaults.standard.set(data, forKey: backupKey)
      }
    }
    for s in services {
      _ = run(["-setwebproxy", s, host, "\(httpPort)"])
      _ = run(["-setwebproxystate", s, "on"])
      _ = run(["-setsecurewebproxy", s, host, "\(httpPort)"])
      _ = run(["-setsecurewebproxystate", s, "on"])
      _ = run(["-setsocksfirewallproxy", s, host, "\(socksPort)"])
      _ = run(["-setsocksfirewallproxystate", s, "on"])
    }
    UserDefaults.standard.set(true, forKey: managedKey)
  }

  /// Restore backup if present; otherwise turn proxies off.
  static func disable() throws {
    defer { UserDefaults.standard.set(false, forKey: managedKey) }
    if let data = UserDefaults.standard.data(forKey: backupKey),
       let snaps = try? JSONDecoder().decode([ServiceSnapshot].self, from: data)
    {
      for snap in snaps {
        restore(snap)
      }
      UserDefaults.standard.removeObject(forKey: backupKey)
      return
    }
    for s in listServices() {
      _ = run(["-setwebproxystate", s, "off"])
      _ = run(["-setsecurewebproxystate", s, "off"])
      _ = run(["-setsocksfirewallproxystate", s, "off"])
    }
  }

  /// Best-effort cleanup on app quit.
  static func disableIfManaged() {
    if isManagedEnabled() {
      try? disable()
    }
    if isDnsManaged() {
      try? disableTunDns()
    }
  }

  // MARK: - TUN DNS (macOS leak fix)

  static func isDnsManaged() -> Bool {
    UserDefaults.standard.bool(forKey: dnsManagedKey)
  }

  /// Point active network services at TUN DNS peers (e.g. 172.19.0.2).
  /// LAN DHCP DNS stays on-link and never enters TUN, so hijack-dns alone leaks.
  static func enableTunDns(servers: [String]) throws {
    let cleaned = servers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if cleaned.isEmpty {
      throw ProxyError.message("DNS servers required")
    }
    let services = listServices()
    if services.isEmpty {
      throw ProxyError.message("未找到可用网络服务")
    }
    if !isDnsManaged() {
      let snaps = services.map { dnsSnapshot(service: $0) }
      if let data = try? JSONEncoder().encode(snaps) {
        UserDefaults.standard.set(data, forKey: dnsBackupKey)
      }
    }
    for s in services {
      var args = ["-setdnsservers", s]
      args.append(contentsOf: cleaned)
      _ = run(args)
    }
    UserDefaults.standard.set(true, forKey: dnsManagedKey)
  }

  /// Restore DNS backup, or clear to DHCP (`Empty`).
  static func disableTunDns() throws {
    defer { UserDefaults.standard.set(false, forKey: dnsManagedKey) }
    if let data = UserDefaults.standard.data(forKey: dnsBackupKey),
       let snaps = try? JSONDecoder().decode([DnsSnapshot].self, from: data)
    {
      for snap in snaps {
        restoreDns(snap)
      }
      UserDefaults.standard.removeObject(forKey: dnsBackupKey)
      return
    }
    for s in listServices() {
      _ = run(["-setdnsservers", s, "Empty"])
    }
  }

  // MARK: - helpers

  private static func listServices() -> [String] {
    let out = run(["-listallnetworkservices"]) ?? ""
    return out
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") }
  }

  private static func proxyEnabled(service: String, flag: String) -> Bool {
    let out = run([flag, service]) ?? ""
    for line in out.split(whereSeparator: \.isNewline) {
      let s = String(line)
      if s.lowercased().hasPrefix("enabled:") {
        return s.lowercased().contains("yes")
      }
    }
    return false
  }

  private static func snapshot(service: String) -> ServiceSnapshot {
    func parse(_ flag: String) -> (Bool, String, Int) {
      let out = run([flag, service]) ?? ""
      var enabled = false
      var server = ""
      var port = 0
      for line in out.split(whereSeparator: \.isNewline) {
        let parts = String(line).split(separator: ":", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { continue }
        switch parts[0].lowercased() {
        case "enabled":
          enabled = parts[1].lowercased().hasPrefix("y")
        case "server":
          server = parts[1]
        case "port":
          port = Int(parts[1]) ?? 0
        default:
          break
        }
      }
      return (enabled, server, port)
    }
    let web = parse("-getwebproxy")
    let secure = parse("-getsecurewebproxy")
    let socks = parse("-getsocksfirewallproxy")
    return ServiceSnapshot(
      name: service,
      webEnabled: web.0,
      webHost: web.1,
      webPort: web.2,
      secureEnabled: secure.0,
      secureHost: secure.1,
      securePort: secure.2,
      socksEnabled: socks.0,
      socksHost: socks.1,
      socksPort: socks.2
    )
  }

  private static func restore(_ snap: ServiceSnapshot) {
    let s = snap.name
    if snap.webEnabled, !snap.webHost.isEmpty, snap.webPort > 0 {
      _ = run(["-setwebproxy", s, snap.webHost, "\(snap.webPort)"])
      _ = run(["-setwebproxystate", s, "on"])
    } else {
      _ = run(["-setwebproxystate", s, "off"])
    }
    if snap.secureEnabled, !snap.secureHost.isEmpty, snap.securePort > 0 {
      _ = run(["-setsecurewebproxy", s, snap.secureHost, "\(snap.securePort)"])
      _ = run(["-setsecurewebproxystate", s, "on"])
    } else {
      _ = run(["-setsecurewebproxystate", s, "off"])
    }
    if snap.socksEnabled, !snap.socksHost.isEmpty, snap.socksPort > 0 {
      _ = run(["-setsocksfirewallproxy", s, snap.socksHost, "\(snap.socksPort)"])
      _ = run(["-setsocksfirewallproxystate", s, "on"])
    } else {
      _ = run(["-setsocksfirewallproxystate", s, "off"])
    }
  }

  private static func dnsSnapshot(service: String) -> DnsSnapshot {
    let out = run(["-getdnsservers", service]) ?? ""
    let lower = out.lowercased()
    if lower.contains("aren't any dns") || lower.contains("there aren't any") {
      return DnsSnapshot(name: service, servers: [])
    }
    let servers = out
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return DnsSnapshot(name: service, servers: servers)
  }

  private static func restoreDns(_ snap: DnsSnapshot) {
    if snap.servers.isEmpty {
      _ = run(["-setdnsservers", snap.name, "Empty"])
    } else {
      var args = ["-setdnsservers", snap.name]
      args.append(contentsOf: snap.servers)
      _ = run(args)
    }
  }

  @discardableResult
  private static func run(_ args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
      try proc.run()
      proc.waitUntilExit()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }

  enum ProxyError: LocalizedError {
    case message(String)
    var errorDescription: String? {
      switch self {
      case .message(let m): return m
      }
    }
  }
}
