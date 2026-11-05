import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Keep proxy/TUN alive when the user closes the window (Dock / Cmd+Q to quit).
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication)
    -> Bool
  {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Clicking the Dock icon reopens the dashboard if all windows were closed.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if flag { return true }
    if let window = mainFlutterWindow {
      window.makeKeyAndOrderFront(nil)
    } else {
      for window in NSApp.windows {
        window.makeKeyAndOrderFront(nil)
      }
    }
    NSApp.activate(ignoringOtherApps: true)
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    // Avoid leaving system proxy / helper-side core running after quit.
    SystemProxyManager.disableIfManaged()
    HelperSocketClient.stopTunIfPossible()
    if SingBoxCoreLoader.shared.isRunning() {
      try? SingBoxCoreLoader.shared.stop()
    }
  }
}
