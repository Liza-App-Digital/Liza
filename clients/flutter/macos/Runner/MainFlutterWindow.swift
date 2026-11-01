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
  private var channel: FlutterMethodChannel?
  private var observers: [NSObjectProtocol] = []
  private var closed = false
  private var visibilityEpoch = 0
  private var snapshotSequence = 0
  private var focusEpoch = 0
  private var mainFocusEpoch = 0
  private var directMainFocusEpoch = -1
  private weak var previousKeyWindow: NSWindow?

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  private func visibility() -> [String: Any] {
    let window = registrar?.view?.window
    snapshotSequence += 1
    return [
      "sequence": snapshotSequence,
      "focus_epoch": focusEpoch,
      "main_focus_epoch": mainFocusEpoch,
      "direct_main_focus_epoch": directMainFocusEpoch,
      "visibility_epoch": visibilityEpoch,
      "closed": closed || window == nil,
      "visible": window?.isVisible == true && NSApp.isActive,
      "minimized": window?.isMiniaturized == true,
      "focused": window?.isKeyWindow == true && NSApp.isActive,
      "main_focused": NSApp.isActive && NSApp.windows.contains {
        $0 is MainFlutterWindow && $0.isKeyWindow && $0.isVisible && !$0.isMiniaturized
      },
    ]
  }

  private func observeVisibility() {
    guard observers.isEmpty else { return }
    previousKeyWindow = NSApp.keyWindow
    let names: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
      NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
      NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
      NSApplication.didHideNotification, NSApplication.didUnhideNotification,
    ]
    for name in names {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] note in
        guard let self = self else { return }
        let ownWindow = (note.object as? NSWindow) === self.registrar?.view?.window
        if note.name == NSWindow.didResignKeyNotification {
          if ownWindow {
            self.focusEpoch += 1
            self.directMainFocusEpoch = -1
          }
          if note.object is MainFlutterWindow { self.mainFocusEpoch += 1 }
        }
        if note.name == NSWindow.didBecomeKeyNotification,
           let destination = note.object as? NSWindow {
          // History обновляется синхронно, до отложенной публикации snapshot.
          // A→B→main не превращается в A→main при слиянии callbacks.
          self.directMainFocusEpoch =
            destination is MainFlutterWindow &&
            self.previousKeyWindow === self.registrar?.view?.window
              ? self.focusEpoch : -1
          self.previousKeyWindow = destination
        }
        if (ownWindow && (note.name == NSWindow.didMiniaturizeNotification ||
                          note.name == NSWindow.willCloseNotification)) ||
           note.name == NSApplication.didResignActiveNotification ||
           note.name == NSApplication.didHideNotification {
          self.visibilityEpoch += 1
        }
        if note.name == NSWindow.willCloseNotification,
           let window = note.object as? NSWindow, window === self.registrar?.view?.window {
          self.closed = true
        }
        // Смена key-window состоит из resign + become; читаем итоговое
        // состояние после текущей транзакции, не отменяя свой main-picker.
        DispatchQueue.main.async { [weak self] in
          guard let self = self else { return }
          self.channel?.invokeMethod("visibilityChanged", arguments: self.visibility())
        }
      })
    }
  }

  init(_ registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "liza/miniapp_window", binaryMessenger: registrar.messenger)
    let plugin = MiniAppWindowPlugin(registrar)
    plugin.channel = channel
    plugin.observeVisibility()
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let window = registrar?.view?.window else {
      result(FlutterError(code: "no_window", message: nil, details: nil))
      return
    }
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "visibility":
      result(visibility())
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
