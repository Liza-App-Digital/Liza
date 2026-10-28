import Cocoa
import FlutterMacOS
import desktop_multi_window
import flutter_inappwebview_macos
import url_launcher_macos

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.minSize = NSSize(width: 480, height: 400)
    self.setFrameAutosaveName("MainFlutterWindow")

    let restored = self.setFrameUsingName(self.frameAutosaveName)
    if !restored || self.frame.width < 480 || self.frame.height < 400 {
      self.setFrame(NSRect(x: 0, y: 0, width: 960, height: 700), display: true)
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Движок окна mini App (desktop_multi_window) получает ТОЛЬКО то, что
    // нужно WebView: RegisterGeneratedPlugins там перехватил бы делегат
    // UNUserNotificationCenter (flutter_local_notifications) и Apple Events
    // deep-link (app_links) у главного движка.
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      InAppWebViewFlutterPlugin.register(
        with: controller.registrar(forPlugin: "InAppWebViewFlutterPlugin"))
      UrlLauncherPlugin.register(
        with: controller.registrar(forPlugin: "UrlLauncherPlugin"))
      MiniAppWindowPlugin.register(
        with: controller.registrar(forPlugin: "MiniAppWindowPlugin"))
    }

    super.awakeFromNib()
  }

  override func close() {
    // Hide the window instead of closing it so the app stays in the Dock.
    // Using orderOut alone is fine — the window can be restored via
    // applicationShouldHandleReopen or applicationDidBecomeActive.
    if self.isMiniaturized {
      self.deminiaturize(nil)
    }
    self.orderOut(self)
  }
}

/// Окно ОС mini App со стороны его движка: заголовок, размер, фокус, закрытие
/// (канал `liza/miniapp_window`, см. mini_app_window.dart). Свой канал, а не
/// window_manager: тот ставит себя делегатом окна и умеет terminate.
class MiniAppWindowPlugin: NSObject, FlutterPlugin {
  /// Позиция и размер окна запоминаются между открытиями и запусками.
  private static let frameName = "LizaMiniAppWindow"

  private weak var registrar: FlutterPluginRegistrar?

  init(_ registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "liza/miniapp_window", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(MiniAppWindowPlugin(registrar), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let window = registrar?.view?.window else {
      result(FlutterError(code: "no_window", message: nil, details: nil))
      return
    }
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "present":
      window.title = args?["title"] as? String ?? ""
      window.minSize = NSSize(width: 360, height: 480)
      if !window.setFrameUsingName(MiniAppWindowPlugin.frameName) {
        window.setFrame(MiniAppWindowPlugin.defaultFrame(), display: false)
      }
      // Автосохранение — только у одного окна с этим именем; у второго
      // одновременно открытого mini App вызов просто вернёт false.
      window.setFrameAutosaveName(MiniAppWindowPlugin.frameName)
      MiniAppWindowPlugin.focus(window)
      result(nil)
    case "setTitle":
      window.title = args?["title"] as? String ?? ""
      result(nil)
    case "focus":
      MiniAppWindowPlugin.focus(window)
      result(nil)
    case "close":
      window.close()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func focus(_ window: NSWindow) {
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Большое окно по центру экрана, на котором стоит Лиза.
  private static func defaultFrame() -> NSRect {
    let main = NSApp.windows.first { $0 is MainFlutterWindow }
    let screen = main?.screen ?? NSScreen.main ?? NSScreen.screens.first
    let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let width = min(1100, area.width * 0.9)
    let height = min(820, area.height * 0.9)
    return NSRect(
      x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
  }
}
