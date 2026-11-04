import Foundation

/// Loads `libsingboxcore.dylib` via dlopen and binds the C ABI.
final class SingBoxCoreLoader {
  static let shared = SingBoxCoreLoader()

  private var handle: UnsafeMutableRawPointer?
  private var loadError: String = "not loaded"

  typealias VersionFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
  typealias FreeStringFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
  typealias StartFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
  typealias StopFn = @convention(c) () -> Int32
  typealias IsRunningFn = @convention(c) () -> Int32
  typealias StatusJSONFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
  typealias MemoryJSONFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
  typealias ClashAPIFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
  typealias LastErrorFn = @convention(c) () -> UnsafeMutablePointer<CChar>?

  private var versionFn: VersionFn?
  private var freeStringFn: FreeStringFn?
  private var startFn: StartFn?
  private var stopFn: StopFn?
  private var isRunningFn: IsRunningFn?
  private var statusJSONFn: StatusJSONFn?
  private var memoryJSONFn: MemoryJSONFn?
  private var clashAPIFn: ClashAPIFn?
  private var lastErrorFn: LastErrorFn?

  var isLoaded: Bool { handle != nil }

  var lastLoadError: String { loadError }

  @discardableResult
  func ensureLoaded() -> Bool {
    if handle != nil { return true }
    return load()
  }

  func load() -> Bool {
    if let handle {
      dlclose(handle)
      self.handle = nil
    }

    let candidates = Self.dylibCandidatePaths()
    var errors: [String] = []
    for path in candidates {
      guard FileManager.default.fileExists(atPath: path) else {
        errors.append("missing: \(path)")
        continue
      }
      guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        errors.append("dlopen(\(path)): \(String(cString: dlerror()))")
        continue
      }
      handle = h
      if bindSymbols(h) {
        loadError = ""
        return true
      }
      errors.append("symbol bind failed for \(path)")
      dlclose(h)
      handle = nil
    }
    loadError = errors.joined(separator: " | ")
    return false
  }

  /// Public so Helper can be pointed at the same dylib the app loads.
  static func dylibCandidatePaths() -> [String] {
    var paths: [String] = []
    if let builtIn = Bundle.main.privateFrameworksPath {
      paths.append((builtIn as NSString).appendingPathComponent("libsingboxcore.dylib"))
    }
    if let res = Bundle.main.resourcePath {
      paths.append((res as NSString).appendingPathComponent("libsingboxcore.dylib"))
      paths.append((res as NSString).appendingPathComponent("Frameworks/libsingboxcore.dylib"))
    }
    // Dev fallback: repo-relative when running from Xcode / flutter run.
    var repo = (#file as NSString).deletingLastPathComponent // Runner
    repo = (repo as NSString).deletingLastPathComponent // macos
    repo = (repo as NSString).deletingLastPathComponent // repo root
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "amd64"
    #endif
    paths.append((repo as NSString).appendingPathComponent("native/singboxcore/build/\(arch)/libsingboxcore.dylib"))
    paths.append((repo as NSString).appendingPathComponent("native/singboxcore/build/universal/libsingboxcore.dylib"))
    return paths
  }

  private func bindSymbols(_ h: UnsafeMutableRawPointer) -> Bool {
    func sym<T>(_ name: String) -> T? {
      guard let raw = dlsym(h, name) else { return nil }
      return unsafeBitCast(raw, to: T.self)
    }
    versionFn = sym("SingletVersion")
    freeStringFn = sym("SingletFreeString")
    startFn = sym("SingletStart")
    stopFn = sym("SingletStop")
    isRunningFn = sym("SingletIsRunning")
    statusJSONFn = sym("SingletStatusJSON")
    memoryJSONFn = sym("SingletMemoryJSON")
    clashAPIFn = sym("SingletClashAPIBaseURL")
    lastErrorFn = sym("SingletLastError")
    return versionFn != nil
      && freeStringFn != nil
      && startFn != nil
      && stopFn != nil
      && isRunningFn != nil
  }

  private func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr else { return "" }
    defer { freeStringFn?(ptr) }
    return String(cString: ptr)
  }

  func version() -> String {
    guard ensureLoaded(), let versionFn else {
      return "unloadable: \(loadError)"
    }
    return takeString(versionFn())
  }

  func lastError() -> String {
    guard ensureLoaded(), let lastErrorFn else { return loadError }
    return takeString(lastErrorFn())
  }

  func isRunning() -> Bool {
    guard ensureLoaded(), let isRunningFn else { return false }
    return isRunningFn() != 0
  }

  func clashApiBase() -> String {
    guard ensureLoaded(), let clashAPIFn else { return "" }
    return takeString(clashAPIFn())
  }

  func statusJSON() -> [String: Any] {
    guard ensureLoaded(), let statusJSONFn else {
      return [
        "stub": false,
        "loaded": false,
        "running": false,
        "error": loadError,
      ]
    }
    let raw = takeString(statusJSONFn())
    if let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      var merged = obj
      merged["loaded"] = true
      return merged
    }
    return ["raw": raw, "loaded": true]
  }

  /// Go runtime MemStats (inuse/oslimit). Empty map if symbol missing / unloadable.
  func memoryJSON() -> [String: Any] {
    guard ensureLoaded(), let memoryJSONFn else { return [:] }
    let raw = takeString(memoryJSONFn())
    if let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      return obj
    }
    return [:]
  }

  func start(configPath: String, clashApiBaseUrl: String) throws {
    guard ensureLoaded(), let startFn else {
      throw LoaderError.notLoaded(loadError)
    }
    let code = configPath.withCString { pathPtr in
      clashApiBaseUrl.withCString { apiPtr in
        startFn(pathPtr, apiPtr)
      }
    }
    if code != 0 {
      throw LoaderError.startFailed(lastError())
    }
  }

  func stop() throws {
    guard ensureLoaded(), let stopFn else {
      throw LoaderError.notLoaded(loadError)
    }
    let code = stopFn()
    if code != 0 {
      throw LoaderError.stopFailed(lastError())
    }
  }

  enum LoaderError: LocalizedError {
    case notLoaded(String)
    case startFailed(String)
    case stopFailed(String)

    var errorDescription: String? {
      switch self {
      case .notLoaded(let m): return "dylib not loaded: \(m)"
      case .startFailed(let m): return "SingletStart failed: \(m)"
      case .stopFailed(let m): return "SingletStop failed: \(m)"
      }
    }
  }
}
