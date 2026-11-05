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

    // Empty title (no product name). Keep titleVisibility visible —
    // .hidden has been linked to Impeller zero-size / null render-target crashes.
    self.title = ""

    super.awakeFromNib()
  }
}
