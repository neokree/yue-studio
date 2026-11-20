import Cocoa
import FlutterMacOS
import macos_window_utils

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let windowFrame = self.frame
    // macos_window_utils needs its own view controller so the Flutter view can sit on a vibrancy view.
    let macOSWindowUtilsViewController = MacOSWindowUtilsViewController()
    self.contentViewController = macOSWindowUtilsViewController
    self.setFrame(windowFrame, display: true)
    // First run lists up to 8 steps: open large enough to show them all; the content scrolls below this.
    self.setContentSize(NSSize(width: 1040, height: 780))
    self.contentMinSize = NSSize(width: 860, height: 560)
    self.center()

    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    RegisterGeneratedPlugins(registry: macOSWindowUtilsViewController.flutterViewController)

    // The Flutter view covers the title bar, so Dart's TitleBarStrip asks us to do what the title bar would.
    let channel = FlutterMethodChannel(
      name: "yue2/window",
      binaryMessenger: macOSWindowUtilsViewController.flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "doubleClick":
        // System Settings > Desktop & Dock > "Double-click a window's title bar to": Maximize (default), Minimize, None.
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize": self.performMiniaturize(nil)
        case "None": break
        default: self.performZoom(nil)
        }
        result(nil)
      case "drag":
        if let event = NSApp.currentEvent { self.performDrag(with: event) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
