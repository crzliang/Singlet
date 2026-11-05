import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    SingletNativeChannels.register(messenger: flutterViewController.engine.binaryMessenger)

    // No product name in the title bar.
    self.title = ""
    self.titleVisibility = .hidden

    super.awakeFromNib()
  }
}
