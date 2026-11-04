import Foundation
import AppKit

/// Personal-MVP privileged helper install via `osascript` admin elevation.
/// Copies bundled helper + launchd plist into system paths and bootstraps launchd.
enum HelperInstaller {
  static let label = "com.singlet.PrivilegedHelper"
  static let installPath = "/Library/PrivilegedHelperTools/com.singlet.PrivilegedHelper"
  static let plistPath = "/Library/LaunchDaemons/com.singlet.PrivilegedHelper.plist"

  struct Status {
    let installed: Bool
    let running: Bool
    let text: String
  }

  static func currentStatus() -> Status {
    // Prefer existence over isExecutableFile — some macOS builds return false
    // for root-owned helpers even when world-executable.
    let binOK = FileManager.default.fileExists(atPath: installPath)
    let plistOK = FileManager.default.fileExists(atPath: plistPath)
    let socketOK = FileManager.default.fileExists(atPath: HelperSocketClient.socketPath)
      || (try? HelperSocketClient.ping()) != nil
    let running = isLaunchdLoaded() || socketOK
    // Socket reachable ⇒ treat as installed even if path probes fail (TCC / path quirks).
    if (binOK && plistOK) || socketOK {
      let text: String
      if socketOK {
        text = "已安装且 Helper socket 可达 (\(HelperSocketClient.socketPath))"
      } else if running {
        text = "已安装且 launchd 已加载 (\(installPath))"
      } else {
        text = "已安装但 Helper 未响应（可重装）"
      }
      return Status(installed: true, running: running || socketOK, text: text)
    }
    return Status(
      installed: false,
      running: false,
      text: "未安装（点击一键安装将弹出管理员密码）"
    )
  }

  static func isLaunchdLoaded() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["print", "system/\(label)"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do {
      try task.run()
      task.waitUntilExit()
      return task.terminationStatus == 0
    } catch {
      return false
    }
  }

  /// Returns a map suitable for Flutter MethodChannel.
  static func install() throws -> [String: Any] {
    guard let helperURL = bundledHelperURL() else {
      throw InstallError.missingBundle(
        "应用内未找到 Helper 二进制。请先 rebuild（scripts/build_privileged_helper.sh）。"
      )
    }
    guard let plistURL = bundledPlistURL() else {
      throw InstallError.missingBundle("应用内未找到 Helper launchd plist。")
    }

    let shell = buildInstallShellScript(
      helperSrc: helperURL.path,
      plistSrc: plistURL.path
    )
    let output = try runAdminShell(shell)

    Thread.sleep(forTimeInterval: 0.4)
    let status = currentStatus()
    if !status.installed {
      throw InstallError.failed(
        "管理员脚本已执行，但未检测到已安装文件。输出: \(output.isEmpty ? "(空)" : output)"
      )
    }
    return [
      "ok": true,
      "installed": status.installed,
      "running": status.running,
      "message": status.running
        ? "Helper 已安装并启动"
        : "Helper 文件已安装，但 launchd 可能未拉起（查看 /tmp/com.singlet.PrivilegedHelper.err.log）",
      "output": output,
      "path": installPath,
    ]
  }

  /// Shell body written to a temp `.sh` (paths are shell-escaped here only).
  static func buildInstallShellScript(helperSrc: String, plistSrc: String) -> String {
    let h = shQuote(helperSrc)
    let p = shQuote(plistSrc)
    let destBin = shQuote(installPath)
    let destPlist = shQuote(plistPath)
    // Absolute paths must match macOS layout (chown is under /usr/sbin, not /usr/bin).
    return """
    #!/bin/bash
    set -euo pipefail
    /bin/mkdir -p /Library/PrivilegedHelperTools
    /bin/cp -f \(h) \(destBin)
    /bin/chmod 755 \(destBin)
    /usr/sbin/chown root:wheel \(destBin)
    /bin/cp -f \(p) \(destPlist)
    /bin/chmod 644 \(destPlist)
    /usr/sbin/chown root:wheel \(destPlist)
    /bin/launchctl bootout system/\(label) 2>/dev/null || true
    /bin/launchctl bootstrap system \(destPlist)
    /bin/launchctl enable system/\(label)
    /bin/launchctl kickstart -k system/\(label)
    """
  }

  /// AppleScript that runs an on-disk shell script with admin privileges.
  /// Uses `quoted form of` — never embeds bash-style `'...'` in AppleScript.
  static func buildAdminAppleScript(scriptPath: String) -> String {
    let literal = appleScriptStringLiteral(scriptPath)
    return """
    do shell script "/bin/bash " & quoted form of \(literal) with administrator privileges
    """
  }

  private static func bundledHelperURL() -> URL? {
    if let u = Bundle.main.url(
      forResource: "com.singlet.PrivilegedHelper",
      withExtension: nil,
      subdirectory: "Helper"
    ) {
      return u
    }
    let repo = repoRootFromSource()
    let candidate = (repo as NSString)
      .appendingPathComponent("helper/SingletPrivilegedHelper/build/com.singlet.PrivilegedHelper")
    return FileManager.default.isExecutableFile(atPath: candidate)
      ? URL(fileURLWithPath: candidate)
      : nil
  }

  private static func bundledPlistURL() -> URL? {
    if let u = Bundle.main.url(
      forResource: "com.singlet.PrivilegedHelper",
      withExtension: "plist",
      subdirectory: "Helper"
    ) {
      return u
    }
    let repo = repoRootFromSource()
    let candidate = (repo as NSString)
      .appendingPathComponent(
        "helper/SingletPrivilegedHelper/build/com.singlet.PrivilegedHelper.plist"
      )
    return FileManager.default.fileExists(atPath: candidate)
      ? URL(fileURLWithPath: candidate)
      : nil
  }

  private static func repoRootFromSource() -> String {
    var repo = (#file as NSString).deletingLastPathComponent
    repo = (repo as NSString).deletingLastPathComponent
    repo = (repo as NSString).deletingLastPathComponent
    return repo
  }

  /// POSIX shell single-quote escape for paths inside the `.sh` file.
  private static func shQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// AppleScript `"..."` string literal (not shell quoting).
  private static func appleScriptStringLiteral(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  /// Prompts for admin password via AppleScript `with administrator privileges`.
  private static func runAdminShell(_ script: String) throws -> String {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("singlet-helper-install-\(UUID().uuidString).sh")
    try script.write(to: tmp, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: tmp.path
    )
    // Keep script until osascript finishes; then remove.
    defer { try? FileManager.default.removeItem(at: tmp) }

    let appleScript = buildAdminAppleScript(scriptPath: tmp.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", appleScript]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
      let combined = (stderr.isEmpty ? stdout : stderr)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let lower = combined.lowercased()
      if lower.contains("user canceled")
        || lower.contains("user cancelled")
        || combined.contains("-128")
      {
        throw InstallError.cancelled
      }
      throw InstallError.failed(
        combined.isEmpty
          ? "osascript exit \(process.terminationStatus)"
          : combined
      )
    }
    return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  enum InstallError: LocalizedError {
    case missingBundle(String)
    case failed(String)
    case cancelled

    var errorDescription: String? {
      switch self {
      case .missingBundle(let m): return m
      case .failed(let m): return m
      case .cancelled: return "用户取消了管理员授权"
      }
    }

    var code: String {
      switch self {
      case .missingBundle: return "missing_bundle"
      case .failed: return "install_failed"
      case .cancelled: return "cancelled"
      }
    }
  }
}
