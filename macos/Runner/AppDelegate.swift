import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
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
