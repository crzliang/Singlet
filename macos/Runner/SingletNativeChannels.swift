import Cocoa
import FlutterMacOS

/// MethodChannels for embedded core + privileged helper + system proxy.
enum SingletNativeChannels {
  static let coreChannelName = "com.singlet/singbox_core"
  static let helperChannelName = "com.singlet/helper"
  static let proxyChannelName = "com.singlet/system_proxy"

  static func register(messenger: FlutterBinaryMessenger) {
    // Don't block first frame on ~30MB dylib dlopen — warm in background.
    DispatchQueue.global(qos: .userInitiated).async {
      _ = SingBoxCoreLoader.shared.ensureLoaded()
    }
    registerCore(messenger: messenger)
    registerHelper(messenger: messenger)
    registerSystemProxy(messenger: messenger)
  }

  private static func registerCore(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: coreChannelName,
      binaryMessenger: messenger
    )
    let core = SingBoxCoreLoader.shared
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "version":
        result(core.version())
      case "isRunning":
        result(core.isRunning())
      case "status":
        result(core.statusJSON())
      case "memory":
        result(core.memoryJSON())
      case "start":
        guard let args = call.arguments as? [String: Any],
              let path = args["configPath"] as? String,
              !path.isEmpty
        else {
          result(
            FlutterError(
              code: "bad_args",
              message: "configPath required",
              details: nil
            )
          )
          return
        }
        let api = (args["clashApiBaseUrl"] as? String) ?? "http://127.0.0.1:9090"
        let force = (args["force"] as? Bool) ?? false
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            if core.isRunning() {
              if force {
                try core.stop()
              } else {
                try core.stop()
              }
            }
            try core.start(configPath: path, clashApiBaseUrl: api)
            DispatchQueue.main.async { result(nil) }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "start_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      case "stop":
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            if core.isRunning() {
              try core.stop()
            }
            DispatchQueue.main.async { result(nil) }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "stop_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func registerHelper(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: helperChannelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isInstalled":
        result(HelperInstaller.currentStatus().installed)
      case "status":
        result(HelperInstaller.currentStatus().text)
      case "install":
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let payload = try HelperInstaller.install()
            DispatchQueue.main.async { result(payload) }
          } catch let error as HelperInstaller.InstallError {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: error.code,
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "install_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      case "tunPing":
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let payload = try HelperSocketClient.ping()
            DispatchQueue.main.async { result(payload) }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "helper_unreachable",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      case "tunStatus":
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let payload = try HelperSocketClient.status()
            DispatchQueue.main.async { result(payload) }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "helper_unreachable",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      case "tunStart":
        guard let args = call.arguments as? [String: Any],
              let configPath = args["configPath"] as? String,
              !configPath.isEmpty
        else {
          result(
            FlutterError(
              code: "bad_args",
              message: "configPath required",
              details: nil
            )
          )
          return
        }
        let clashApi =
          (args["clashApiBaseUrl"] as? String) ?? "http://127.0.0.1:9090"
        let httpPort = (args["httpPort"] as? Int) ?? 17890
        let apiPort = (args["apiPort"] as? Int) ?? 9090
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            guard let dylibSrc = HelperSocketClient.resolveDylibPath() else {
              throw HelperSocketClient.HelperSockError.message(
                "找不到 libsingboxcore.dylib"
              )
            }
            // App-process core holds mixed/Clash ports — must fully release
            // before helper (root) SingletStart, or tun comes up then rolls back.
            if SingBoxCoreLoader.shared.isRunning() {
              try? SingBoxCoreLoader.shared.stop()
            }
            let free = PortProbe.waitUntilFree(ports: [httpPort, apiPort])
            if !free {
              throw HelperSocketClient.HelperSockError.message(
                "端口 \(httpPort)/\(apiPort) 仍被占用（多为应用内核心未停净）。请先点断开再开 TUN。"
              )
            }
            // Stable path for root dlopen (avoid transient/build paths).
            let dylib = try HelperSocketClient.stageDylib(dylibSrc)
            let payload = try HelperSocketClient.startTun(
              configPath: configPath,
              dylibPath: dylib,
              clashApi: clashApi
            )
            // Confirm helper-side box actually stayed up.
            let st = try HelperSocketClient.status()
            if st["running"] as? Bool != true {
              throw HelperSocketClient.HelperSockError.message(
                "Helper 回报未在运行（TUN 可能启动失败后回滚）"
              )
            }
            var out = payload
            out["verified"] = true
            out["dylibPath"] = dylib
            DispatchQueue.main.async { result(out) }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "tun_start_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      case "tunStop":
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            // Clear TUN DNS first (LAN DHCP), then stop the helper core.
            try? SystemProxyManager.disableTunDns()
            let payload = try HelperSocketClient.stopTun()
            DispatchQueue.main.async { result(payload) }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "tun_stop_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func registerSystemProxy(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: proxyChannelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "status":
        result(SystemProxyManager.status())
      case "enable":
        guard let args = call.arguments as? [String: Any] else {
          result(
            FlutterError(code: "bad_args", message: "args required", details: nil)
          )
          return
        }
        let host = (args["host"] as? String) ?? "127.0.0.1"
        let httpPort = (args["httpPort"] as? Int) ?? 17890
        let socksPort = (args["socksPort"] as? Int) ?? httpPort
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try SystemProxyManager.enable(
              host: host,
              httpPort: httpPort,
              socksPort: socksPort
            )
            DispatchQueue.main.async { result(["ok": true, "managed": true]) }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "proxy_enable_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      case "disable":
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try SystemProxyManager.disable()
            DispatchQueue.main.async { result(["ok": true, "managed": false]) }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "proxy_disable_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      case "enableTunDns":
        guard let args = call.arguments as? [String: Any],
              let servers = args["servers"] as? [String],
              !servers.isEmpty
        else {
          result(
            FlutterError(
              code: "bad_args",
              message: "servers required",
              details: nil
            )
          )
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try SystemProxyManager.enableTunDns(servers: servers)
            DispatchQueue.main.async {
              result(["ok": true, "dnsManaged": true])
            }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "tun_dns_enable_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      case "disableTunDns":
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try SystemProxyManager.disableTunDns()
            DispatchQueue.main.async {
              result(["ok": true, "dnsManaged": false])
            }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "tun_dns_disable_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
