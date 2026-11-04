import Foundation

/// Line-oriented JSON client for the privileged helper Unix socket.
enum HelperSocketClient {
  static let socketPath = "/var/run/com.singlet.helper.sock"

  static func ping() throws -> [String: Any] {
    try request(["op": "ping"], timeout: 1.5)
  }

  static func status() throws -> [String: Any] {
    try request(["op": "status"], timeout: 2)
  }

  static func startTun(
    configPath: String,
    dylibPath: String,
    clashApi: String
  ) throws -> [String: Any] {
    // Core start can take a while with large configs.
    try request([
      "op": "start",
      "configPath": configPath,
      "dylibPath": dylibPath,
      "clashApi": clashApi,
    ], timeout: 60)
  }

  /// Stop helper core and wait for it to release mixed/Clash listen ports.
  /// Close() under TUN can exceed several seconds — timeout must cover that
  /// plus the helper's post-stop port drain, or the app handoff races.
  static func stopTun(ports: [Int] = [7890, 9090]) throws -> [String: Any] {
    try request(["op": "stop", "ports": ports], timeout: 45)
  }

  /// Best-effort stop on app quit.
  static func stopTunIfPossible() {
    // Restore system DNS before tearing down TUN so the resolver is never stuck
    // on 172.19.0.2 / fdfe:…::2 with no listener.
    try? SystemProxyManager.disableTunDns()
    _ = try? stopTun()
  }

  static func resolveDylibPath() -> String? {
    for path in SingBoxCoreLoader.dylibCandidatePaths() {
      if FileManager.default.fileExists(atPath: path) {
        return path
      }
    }
    return nil
  }

  /// Copy dylib to `/tmp/com.singlet.libsingboxcore.dylib` for reliable root dlopen.
  static func stageDylib(_ source: String) throws -> String {
    let dest = "/tmp/com.singlet.libsingboxcore.dylib"
    let fm = FileManager.default
    if fm.fileExists(atPath: dest) {
      try? fm.removeItem(atPath: dest)
    }
    try fm.copyItem(atPath: source, toPath: dest)
    // World-readable so the root helper can dlopen regardless of umask.
    try fm.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: dest
    )
    return dest
  }

  private static func request(_ obj: [String: Any], timeout: TimeInterval = 25)
    throws -> [String: Any]
  {
    let data = try JSONSerialization.data(withJSONObject: obj)
    guard var line = String(data: data, encoding: .utf8) else {
      throw HelperSockError.message("无法编码请求")
    }
    line += "\n"

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 {
      throw HelperSockError.message("无法创建 socket")
    }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    precondition(pathBytes.count <= 104)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      for i in 0..<pathBytes.count {
        raw[i] = UInt8(bitPattern: pathBytes[i])
      }
    }

    let conn: Int32 = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if conn != 0 {
      throw HelperSockError.message(
        "无法连接 Helper（\(socketPath)）。请确认已安装并运行 Privileged Helper。"
      )
    }

    var timeoutVal = timeval(tv_sec: Int(timeout), tv_usec: 0)
    _ = setsockopt(
      fd,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeoutVal,
      socklen_t(MemoryLayout<timeval>.size)
    )
    _ = setsockopt(
      fd,
      SOL_SOCKET,
      SO_SNDTIMEO,
      &timeoutVal,
      socklen_t(MemoryLayout<timeval>.size)
    )

    let written = line.withCString { ptr in
      Darwin.write(fd, ptr, strlen(ptr))
    }
    if written <= 0 {
      throw HelperSockError.message("写入 Helper 失败")
    }

    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    var collected = Data()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let n = recv(fd, &buffer, buffer.count, 0)
      if n > 0 {
        collected.append(contentsOf: buffer[0..<n])
        if collected.contains(UInt8(ascii: "\n")) { break }
      } else if n == 0 {
        break
      } else {
        // timeout / wouldblock
        if collected.isEmpty { continue }
        break
      }
    }
    guard let text = String(data: collected, encoding: .utf8)?
      .split(separator: "\n", maxSplits: 1)
      .first
      .map(String.init),
      let respData = text.data(using: .utf8),
      let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any]
    else {
      throw HelperSockError.message("Helper 无有效响应")
    }
    if json["ok"] as? Bool != true {
      let err = json["error"] as? String ?? "unknown"
      throw HelperSockError.message(err)
    }
    return json
  }

  enum HelperSockError: LocalizedError {
    case message(String)
    var errorDescription: String? {
      switch self {
      case .message(let m): return m
      }
    }
  }
}
