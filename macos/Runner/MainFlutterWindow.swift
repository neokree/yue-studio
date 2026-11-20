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

    super.awakeFromNib()
  }
}
