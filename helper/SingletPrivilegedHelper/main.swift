import Darwin
import Foundation

/// Privileged helper for TUN: listens on a Unix socket and runs libsingboxcore as root.
/// Installed to `/Library/PrivilegedHelperTools/com.singlet.PrivilegedHelper`.

let helperVersion = "SingletPrivilegedHelper 0.3.2"
let socketPath = "/var/run/com.singlet.helper.sock"

@main
struct SingletPrivilegedHelper {
  static func main() {
    let args = CommandLine.arguments
    if args.contains("--version") {
      print(helperVersion)
      return
    }
    if args.contains("--ping") {
      print("pong")
      return
    }

    let marker = "/tmp/com.singlet.PrivilegedHelper.running"
    try? "\(helperVersion) pid=\(ProcessInfo.processInfo.processIdentifier)\n"
      .write(toFile: marker, atomically: true, encoding: .utf8)

    fputs("\(helperVersion) started under launchd\n", stderr)

    HelperCoreEngine.shared.prepare()
    HelperSocketServer.start()
    RunLoop.main.run()
  }
}

// MARK: - Core (dlopen libsingboxcore)

final class HelperCoreEngine {
  static let shared = HelperCoreEngine()

  // Recursive: start/stop may call isRunning while already holding the lock.
  private let lock = NSRecursiveLock()
  private var handle: UnsafeMutableRawPointer?
  private var loadedPath: String = ""

  typealias StartFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
  typealias StopFn = @convention(c) () -> Int32
  typealias IsRunningFn = @convention(c) () -> Int32
  typealias LastErrorFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
  typealias FreeStringFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
  typealias MemoryJSONFn = @convention(c) () -> UnsafeMutablePointer<CChar>?

  private var startFn: StartFn?
  private var stopFn: StopFn?
  private var isRunningFn: IsRunningFn?
  private var lastErrorFn: LastErrorFn?
  private var freeStringFn: FreeStringFn?
  private var memoryJSONFn: MemoryJSONFn?

  func prepare() {}

  func isRunning() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return isRunningFn?() != 0
  }

  func memoryJSON() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    guard let memoryJSONFn, let freeStringFn else { return [:] }
    guard let ptr = memoryJSONFn() else { return [:] }
    defer { freeStringFn(ptr) }
    let raw = String(cString: ptr)
    if let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      return obj
    }
    return [:]
  }

  func start(configPath: String, dylibPath: String, clashApi: String) throws {
    lock.lock()
    defer { lock.unlock() }
    try loadDylib(dylibPath)
    if isRunningFn?() != 0 {
      _ = stopFn?()
    }
    let code = configPath.withCString { pathPtr in
      clashApi.withCString { apiPtr in
        startFn?(pathPtr, apiPtr) ?? -1
      }
    }
    if code != 0 {
      throw HelperError.message(lastError() ?? "SingletStart failed (\(code))")
    }
  }

  func stop() throws {
    lock.lock()
    defer { lock.unlock() }
    guard let stopFn else { return }
    if isRunningFn?() == 0 { return }
    let code = stopFn()
    if code != 0 {
      throw HelperError.message(lastError() ?? "SingletStop failed (\(code))")
    }
  }

  private func loadDylib(_ path: String) throws {
    if handle != nil, loadedPath == path { return }
    if let handle {
      dlclose(handle)
      self.handle = nil
      startFn = nil
      stopFn = nil
      isRunningFn = nil
      lastErrorFn = nil
      freeStringFn = nil
      memoryJSONFn = nil
    }
    guard FileManager.default.fileExists(atPath: path) else {
      throw HelperError.message("dylib 不存在: \(path)")
    }
    guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
      throw HelperError.message("dlopen 失败: \(String(cString: dlerror()))")
    }
    func sym<T>(_ name: String) -> T? {
      guard let raw = dlsym(h, name) else { return nil }
      return unsafeBitCast(raw, to: T.self)
    }
    startFn = sym("SingletStart")
    stopFn = sym("SingletStop")
    isRunningFn = sym("SingletIsRunning")
    lastErrorFn = sym("SingletLastError")
    freeStringFn = sym("SingletFreeString")
    memoryJSONFn = sym("SingletMemoryJSON")
    guard startFn != nil, stopFn != nil, isRunningFn != nil else {
      dlclose(h)
      throw HelperError.message("dylib 缺少 Singlet* 符号")
    }
    handle = h
    loadedPath = path
  }

  private func lastError() -> String? {
    guard let lastErrorFn, let freeStringFn else { return nil }
    guard let ptr = lastErrorFn() else { return nil }
    defer { freeStringFn(ptr) }
    return String(cString: ptr)
  }
}

enum HelperError: Error {
  case message(String)
}

// MARK: - Unix socket server

enum HelperSocketServer {
  static func start() {
    unlink(socketPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      fputs("helper: socket() failed\n", stderr)
      return
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      for i in 0..<pathBytes.count {
        raw[i] = UInt8(bitPattern: pathBytes[i])
      }
    }

    let bindRc: Int32 = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if bindRc != 0 {
      fputs("helper: bind(\(socketPath)) failed errno=\(errno)\n", stderr)
      close(fd)
      return
    }
    chmod(socketPath, 0o666)
    if listen(fd, 8) != 0 {
      fputs("helper: listen failed\n", stderr)
      close(fd)
      return
    }
    fputs("helper: listening on \(socketPath)\n", stderr)

    DispatchQueue.global(qos: .userInitiated).async {
      while true {
        let client = accept(fd, nil, nil)
        if client < 0 { continue }
        DispatchQueue.global(qos: .userInitiated).async {
          handleClient(client)
        }
      }
    }
  }

  private static func handleClient(_ fd: Int32) {
    defer { close(fd) }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var collected = Data()
    while true {
      let n = recv(fd, &buffer, buffer.count, 0)
      if n <= 0 { break }
      collected.append(contentsOf: buffer[0..<n])
      if collected.contains(UInt8(ascii: "\n")) { break }
    }
    guard let line = String(data: collected, encoding: .utf8)?
      .split(separator: "\n", maxSplits: 1)
      .first
      .map(String.init),
      let data = line.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let op = obj["op"] as? String
    else {
      reply(fd, ["ok": false, "error": "bad request"])
      return
    }

    fputs("helper: op=\(op)\n", stderr)
    do {
      switch op {
      case "ping":
        reply(fd, ["ok": true, "version": helperVersion])
      case "status":
        var payload: [String: Any] = [
          "ok": true,
          "version": helperVersion,
          "running": HelperCoreEngine.shared.isRunning(),
        ]
        let mem = HelperCoreEngine.shared.memoryJSON()
        if let inuse = mem["inuse"] {
          payload["inuse"] = inuse
        }
        if let oslimit = mem["oslimit"] ?? mem["sys"] {
          payload["oslimit"] = oslimit
        }
        if !mem.isEmpty {
          payload["memory"] = mem
        }
        reply(fd, payload)
      case "start":
        guard let configPath = obj["configPath"] as? String,
              let dylibPath = obj["dylibPath"] as? String,
              !configPath.isEmpty,
              !dylibPath.isEmpty
        else {
          throw HelperError.message("configPath/dylibPath required")
        }
        let api = (obj["clashApi"] as? String) ?? "http://127.0.0.1:9090"
        fputs("helper: start config=\(configPath) dylib=\(dylibPath)\n", stderr)
        // Always stop previous helper-side instance first.
        try? HelperCoreEngine.shared.stop()
        try HelperCoreEngine.shared.start(
          configPath: configPath,
          dylibPath: dylibPath,
          clashApi: api
        )
        let running = HelperCoreEngine.shared.isRunning()
        fputs("helper: start done running=\(running)\n", stderr)
        reply(fd, ["ok": true, "running": running])
      case "stop":
        try HelperCoreEngine.shared.stop()
        reply(fd, ["ok": true, "running": false])
      default:
        reply(fd, ["ok": false, "error": "unknown op \(op)"])
      }
    } catch let HelperError.message(m) {
      fputs("helper: error \(m)\n", stderr)
      reply(fd, ["ok": false, "error": m])
    } catch {
      fputs("helper: error \(error.localizedDescription)\n", stderr)
      reply(fd, ["ok": false, "error": error.localizedDescription])
    }
  }

  private static func reply(_ fd: Int32, _ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          var text = String(data: data, encoding: .utf8)
    else { return }
    text += "\n"
    text.withCString { ptr in
      _ = Darwin.write(fd, ptr, strlen(ptr))
    }
  }
}
