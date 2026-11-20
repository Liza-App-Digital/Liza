import Cocoa
import FlutterMacOS
import desktop_multi_window
import flutter_inappwebview_macos
import url_launcher_macos

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Окно Лизы не сжимается «в строку» (Надежда 13.11). Синхронно с
    // WM_GETMINMAXINFO в windows/runner/win32_window.cpp.
    self.minSize = NSSize(width: 480, height: 520)
    self.setFrameAutosaveName("MainFlutterWindow")

    let restored = self.setFrameUsingName(self.frameAutosaveName)
    if !restored || self.frame.width < 480 || self.frame.height < 520 {
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

// BEGIN MINIAPP WINDOW PREFERENCES — без вызовов UI, исполняется host-стражем.
struct MiniAppGeometryContext: Equatable {
  let accountUserId: String
  let kind: String
  let generation: Int

  var preferenceAccount: String? {
    kind == "miniApp" && !accountUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? accountUserId : nil
  }
}

enum MiniAppWindowGeometry {
  static func valid(_ size: NSSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
  }

  static func available(main: NSRect?, area: NSRect) -> NSSize {
    if let main, valid(main.size) {
      let visible = main.intersection(area)
      if !visible.isNull && valid(visible.size) { return visible.size }
    }
    let mainSize = main.flatMap { valid($0.size) ? $0.size : nil } ?? area.size
    return NSSize(width: min(mainSize.width, area.width),
                  height: min(mainSize.height, area.height))
  }

  static func minimum(main: NSRect?, area: NSRect) -> NSSize {
    let cap = available(main: main, area: area)
    return NSSize(width: min(393, cap.width), height: min(520, cap.height))
  }

  static func validPosition(_ point: NSPoint) -> Bool {
    point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
  }

  static func position(frame: NSRect, main: NSRect) -> NSPoint? {
    guard valid(frame.size), valid(main.size), frame.minX.isFinite, frame.minY.isFinite,
          main.minX.isFinite, main.minY.isFinite else { return nil }
    let dx = max(0, main.width - frame.width)
    let dy = max(0, main.height - frame.height)
    return NSPoint(x: dx > 0 ? min(1, max(0, (frame.minX - main.minX) / dx)) : 0.5,
                   y: dy > 0 ? min(1, max(0, (frame.minY - main.minY) / dy)) : 0.5)
  }

  static func frame(preferred: NSSize?, position: NSPoint? = nil,
                    main: NSRect?, area: NSRect) -> NSRect {
    let cap = available(main: main, area: area)
    let minimum = minimum(main: main, area: area)
    let requested = preferred.flatMap { valid($0) ? $0 : nil }
      ?? main.flatMap { valid($0.size) ? $0.size : nil }
      ?? NSSize(width: 960, height: 700)
    let size = NSSize(width: min(cap.width, max(minimum.width, requested.width)),
                      height: min(cap.height, max(minimum.height, requested.height)))
    let center = main ?? area
    let visible = center.intersection(area)
    let bounds = !visible.isNull && valid(visible.size) ? visible : area
    let anchor = position.flatMap { validPosition($0) ? $0 : nil } ?? NSPoint(x: 0.5, y: 0.5)
    let x = center.minX + max(0, center.width - size.width) * anchor.x
    let y = center.minY + max(0, center.height - size.height) * anchor.y
    return NSRect(
      x: max(bounds.minX, min(x, bounds.maxX - size.width)),
      y: max(bounds.minY, min(y, bounds.maxY - size.height)),
      width: size.width, height: size.height)
  }
}

/// Размеры и координаты внешней рамки в points; identity не зависит от номера экрана.
struct MiniAppMonitorPlacement: Equatable {
  let monitor: String
  let size: NSSize
  let position: NSPoint

  var valid: Bool {
    UUID(uuidString: monitor) != nil &&
      MiniAppWindowGeometry.valid(size) && size.width <= 100000 && size.height <= 100000 &&
      MiniAppWindowGeometry.validPosition(position)
  }

  func frame(area: NSRect, matched: Bool = true) -> NSRect {
    MiniAppWindowGeometry.frame(preferred: size,
      position: matched ? position : NSPoint(x: 0.5, y: 0.5), main: area, area: area)
  }
}

enum MiniAppMonitorIdentity {
  static func id(_ screen: NSScreen) -> String? {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
  }

  static func screen(_ identity: String) -> NSScreen? {
    let matches = NSScreen.screens.filter { id($0) == identity }
    return matches.count == 1 ? matches.first : nil
  }

  static func screen(frame: NSRect) -> NSScreen? {
    // Порядок NSScreen.screens детерминирует равное пересечение (основной первым).
    var selected: NSScreen?
    var best: CGFloat = -1
    for screen in NSScreen.screens {
      let intersection = screen.frame.intersection(frame)
      let area = intersection.isNull ? 0 : intersection.width * intersection.height
      if area > best { selected = screen; best = area }
    }
    return selected
  }
}

final class MiniAppWindowPreferences {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  private func key(_ account: String) -> String {
    "liza.miniapp.window.size.v1." + Data(account.utf8).base64EncodedString()
  }

  func read(_ context: MiniAppGeometryContext) -> NSSize? {
    guard let account = context.preferenceAccount,
          let value = defaults.array(forKey: key(account)) as? [Double], value.count == 2 else {
      return nil
    }
    let size = NSSize(width: value[0], height: value[1])
    return MiniAppWindowGeometry.valid(size) ? size : nil
  }

  private func positionKey(_ account: String) -> String {
    "liza.miniapp.window.position.v1." + Data(account.utf8).base64EncodedString()
  }

  func readPosition(_ context: MiniAppGeometryContext) -> NSPoint? {
    guard let account = context.preferenceAccount,
          let value = defaults.array(forKey: positionKey(account)) as? [Double], value.count == 2 else {
      return nil
    }
    let point = NSPoint(x: value[0], y: value[1])
    return MiniAppWindowGeometry.validPosition(point) ? point : nil
  }

  func writePosition(account: String, position: NSPoint) {
    guard !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          MiniAppWindowGeometry.validPosition(position) else { return }
    defaults.set([Double(position.x), Double(position.y)], forKey: positionKey(account))
  }

  private func placementKey(_ account: String) -> String {
    "liza.miniapp.window.placement.v2." + Data(account.utf8).base64EncodedString()
  }

  func readPlacement(_ context: MiniAppGeometryContext) -> MiniAppMonitorPlacement? {
    guard let account = context.preferenceAccount,
          let record = defaults.dictionary(forKey: placementKey(account)),
          record["version"] as? Int == 2,
          let monitor = record["monitor"] as? String,
          let values = record["frame"] as? [Double], values.count == 4 else { return nil }
    let placement = MiniAppMonitorPlacement(monitor: monitor,
      size: NSSize(width: values[0], height: values[1]),
      position: NSPoint(x: values[2], y: values[3]))
    return placement.valid ? placement : nil
  }

  func writePlacement(account: String, placement: MiniAppMonitorPlacement) {
    guard !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          placement.valid else { return }
    defaults.set(["version": 2, "monitor": placement.monitor,
                  "frame": [Double(placement.size.width), Double(placement.size.height),
                            Double(placement.position.x), Double(placement.position.y)]],
                 forKey: placementKey(account))
  }

  func write(account: String, size: NSSize) {
    guard !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          MiniAppWindowGeometry.valid(size) else { return }
    defaults.set([Double(size.width), Double(size.height)], forKey: key(account))
  }
}

/// Capture хранит исходный account; ни close, ни смена контекста его не коммитят.
final class MiniAppManualResize {
  private struct Capture {
    let context: MiniAppGeometryContext
    let size: NSSize
  }
  private var capture: Capture?

  func cancel() { capture = nil }

  func begin(context: MiniAppGeometryContext, size: NSSize,
             normalShown: Bool, mouseResize: Bool, applying: Bool) {
    cancel()
    guard normalShown, mouseResize, !applying, context.preferenceAccount != nil else { return }
    capture = Capture(context: context, size: size)
  }

  func finish(context: MiniAppGeometryContext, size: NSSize,
              normalShown: Bool, applying: Bool) -> (account: String, size: NSSize)? {
    defer { cancel() }
    guard let capture = capture, capture.context == context, normalShown, !applying,
          capture.size != size, MiniAppWindowGeometry.valid(size),
          let account = capture.context.preferenceAccount else { return nil }
    return (account, size)
  }
}
// END MINIAPP WINDOW PREFERENCES

/// Окно ОС mini App со стороны его движка: заголовок, размер, фокус, закрытие
/// (канал `liza/miniapp_window`, см. mini_app_window.dart). Свой канал, а не
/// window_manager: тот ставит себя делегатом окна и умеет terminate.
class MiniAppWindowPlugin: NSObject, FlutterPlugin {
  /// Legacy HTML: 90% монитора и прежний минимум; prefs mini App не участвуют.
  private static let minimumSize = NSSize(width: 800, height: 600)

  private weak var registrar: FlutterPluginRegistrar?
  private var channel: FlutterMethodChannel?
  private var observers: [NSObjectProtocol] = []
  private var geometryObservers: [NSObjectProtocol] = []
  private let preferences: MiniAppWindowPreferences
  private let manualResize = MiniAppManualResize()
  private var geometryContext = MiniAppGeometryContext(accountUserId: "", kind: "", generation: 0)
  private var applyingGeometry = false
  private var moveGeneration = 0
  private var closed = false
  private var visibilityEpoch = 0
  private var snapshotSequence = 0
  private var focusEpoch = 0
  private var mainFocusEpoch = 0
  private var directMainFocusEpoch = -1
  private weak var previousKeyWindow: NSWindow?

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    for observer in geometryObservers { NotificationCenter.default.removeObserver(observer) }
  }

  @discardableResult
  private func updateGeometryContext(_ args: [String: Any]?) -> Bool {
    let context = MiniAppGeometryContext(
      accountUserId: args?["accountUserId"] as? String ?? "",
      kind: args?["kind"] as? String ?? "",
      generation: args?["geometryGeneration"] as? Int ?? 0)
    let policyChanged = context != geometryContext
    if context != geometryContext { manualResize.cancel(); moveGeneration += 1 }
    geometryContext = context
    return policyChanged
  }

  private func normalShown(_ window: NSWindow) -> Bool {
    // AppKit isZoomed — эвристика размера: обычный full-workarea frame тоже
    // true. Ручной resize такого окна допустим; zoom отсечён live/mouse gate.
    !closed && window.isVisible && !window.isMiniaturized &&
      !window.styleMask.contains(.fullScreen) && NSApp.isActive
  }

  private func applyMinimum(_ window: NSWindow, area: NSRect? = nil) {
    let wasApplying = applyingGeometry
    applyingGeometry = true
    defer { applyingGeometry = wasApplying }
    let main = NSApp.windows.first { $0 is MainFlutterWindow }
    let area = area ?? window.screen?.visibleFrame ?? MiniAppWindowPlugin.screenArea()
    window.minSize = geometryContext.kind == "miniApp"
      ? MiniAppWindowGeometry.minimum(
          main: preferences.readPlacement(geometryContext) == nil ? main?.frame : nil, area: area)
      : MiniAppWindowPlugin.fit(MiniAppWindowPlugin.minimumSize, area: area)
  }

  /// Уведомления добавлены отдельно: существующие visibility/focus epochs не меняем.
  private func observeGeometry() {
    guard geometryObservers.isEmpty else { return }
    let names: [Notification.Name] = [
      NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification,
      NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
      NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification,
      NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSApplication.didHideNotification, NSApplication.didResignActiveNotification,
    ]
    for name in names {
      geometryObservers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] note in
        guard let self = self, let window = self.registrar?.view?.window else { return }
        if note.object as? NSApplication != nil {
          self.moveGeneration += 1
          self.manualResize.cancel()
          return
        }
        guard (note.object as? NSWindow) === window else { return }
        switch note.name {
        case NSWindow.willStartLiveResizeNotification:
          let event = NSApp.currentEvent
          let mouseResize = event?.window === window &&
            (event?.type == .leftMouseDown || event?.type == .leftMouseDragged)
          self.manualResize.begin(context: self.geometryContext, size: window.frame.size,
                                  normalShown: self.normalShown(window),
                                  mouseResize: mouseResize, applying: self.applyingGeometry)
        case NSWindow.didEndLiveResizeNotification:
          if let completed = self.manualResize.finish(
            context: self.geometryContext, size: window.frame.size,
            normalShown: self.normalShown(window), applying: self.applyingGeometry) {
            self.savePosition(window, context: self.geometryContext, resized: completed.size)
          }
        case NSWindow.didChangeOcclusionStateNotification:
          if !self.normalShown(window) {
            self.moveGeneration += 1
            self.manualResize.cancel()
          }
        case NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification:
          self.manualResize.cancel()
          self.applyMinimum(window)
        default:
          // Скрытие/смена режима отменяют также ожидающий отпускания move.
          self.moveGeneration += 1
          self.manualResize.cancel()
        }
      })
    }
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
      "maximized": window?.isZoomed == true,
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

  init(_ registrar: FlutterPluginRegistrar,
       preferences: MiniAppWindowPreferences = MiniAppWindowPreferences()) {
    self.registrar = registrar
    self.preferences = preferences
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "liza/miniapp_window", binaryMessenger: registrar.messenger)
    let plugin = MiniAppWindowPlugin(registrar)
    plugin.channel = channel
    plugin.observeVisibility()
    plugin.observeGeometry()
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
      moveGeneration += 1
      updateGeometryContext(args)
      manualResize.cancel()
      applyingGeometry = true
      defer { applyingGeometry = false }
      window.title = args?["title"] as? String ?? ""
      if args?["frameless"] as? Bool == true {
        // .titled/.resizable остаются (borderless не становится key-окном):
        // контент заезжает под прозрачный titlebar, светофор прячем.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
          window.standardWindowButton(button)?.isHidden = true
        }
      }
      var miniAppFrame: NSRect?
      if geometryContext.kind == "miniApp" {
        let main = NSApp.windows.first { $0 is MainFlutterWindow }
        let placement = preferences.readPlacement(geometryContext)
        let screen = placement.flatMap { MiniAppMonitorIdentity.screen($0.monitor) }
        let area = screen?.visibleFrame ?? MiniAppWindowPlugin.screenArea()
        applyMinimum(window, area: area)
        let frame = placement?.frame(area: area, matched: screen != nil) ?? MiniAppWindowGeometry.frame(
          preferred: preferences.read(geometryContext), position: preferences.readPosition(geometryContext),
          main: main?.frame, area: area)
        miniAppFrame = frame
        window.setFrame(frame, display: false)
      } else {
        applyMinimum(window, area: MiniAppWindowPlugin.screenArea())
        window.setFrame(MiniAppWindowPlugin.defaultFrame(), display: false)
      }
      MiniAppWindowPlugin.focus(window)
      if let frame = miniAppFrame {
        // AppKit может сдвинуть впервые показываемое окно на другой монитор.
        // После показа возвращаем рассчитанное положение на выбранном мониторе.
        window.setFrameOrigin(frame.origin)
      }
      result(nil)
    case "setTitle":
      if updateGeometryContext(args) { applyMinimum(window) }
      window.title = args?["title"] as? String ?? ""
      result(nil)
    case "focus":
      MiniAppWindowPlugin.focus(window)
      result(nil)
    case "geometry":
      // macOS width/height исторически измеряют frame, все размеры в pt.
      let area = window.screen?.visibleFrame ?? MiniAppWindowPlugin.screenArea()
      let main = NSApp.windows.first { $0 is MainFlutterWindow }
      let mainFrame = main?.frame ?? NSRect(origin: area.origin, size: area.size)
      result([
        "width": window.frame.width, "height": window.frame.height,
        "frameWidth": window.frame.width, "frameHeight": window.frame.height,
        "minWidth": window.minSize.width, "minHeight": window.minSize.height,
        "minFrameWidth": window.minSize.width, "minFrameHeight": window.minSize.height,
        "mainFrameWidth": mainFrame.width, "mainFrameHeight": mainFrame.height,
        "frameX": window.frame.minX, "frameY": window.frame.minY,
        "mainFrameX": mainFrame.minX, "mainFrameY": mainFrame.minY,
        "areaWidth": area.width, "areaHeight": area.height,
        "maximized": window.isZoomed,
      ])
    case "toggleMaximize":
      moveGeneration += 1
      manualResize.cancel()
      applyingGeometry = true
      defer { applyingGeometry = false }
      window.zoom(nil)
      result(window.isZoomed)
    case "startDrag":
      if let event = NSApp.currentEvent, event.window === window,
         event.type == .leftMouseDown || event.type == .leftMouseDragged,
         normalShown(window), !applyingGeometry {
        moveGeneration += 1
        let generation = moveGeneration
        let context = geometryContext
        let origin = window.frame.origin
        let initialSize = window.frame.size
        window.performDrag(with: event)
        finishManualMove(window, context: context, origin: origin, generation: generation, initialSize: initialSize)
      }
      result(nil)
    case "close":
      moveGeneration += 1
      manualResize.cancel()
      window.close()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func savePosition(_ window: NSWindow, context: MiniAppGeometryContext,
                            resized: NSSize? = nil, initialSize: NSSize? = nil) {
    guard context == geometryContext, !applyingGeometry, normalShown(window),
          let account = context.preferenceAccount,
          let screen = MiniAppMonitorIdentity.screen(frame: window.frame),
          let identity = MiniAppMonitorIdentity.id(screen),
          let position = MiniAppWindowGeometry.position(frame: window.frame, main: screen.visibleFrame) else { return }
    let size = resized ?? preferences.readPlacement(context)?.size ?? preferences.read(context)
      ?? initialSize ?? window.frame.size
    preferences.writePlacement(account: account, placement: MiniAppMonitorPlacement(
      monitor: identity, size: size, position: position))
    applyMinimum(window)
  }

  private func finishManualMove(_ window: NSWindow, context: MiniAppGeometryContext,
                                origin: NSPoint, generation: Int, initialSize: NSSize) {
    guard generation == moveGeneration, context == geometryContext, normalShown(window) else { return }
    // performDrag может вернуть управление до отпускания кнопки мыши.
    if NSEvent.pressedMouseButtons & 1 != 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
        guard let self, let window else { return }
        self.finishManualMove(window, context: context, origin: origin, generation: generation, initialSize: initialSize)
      }
      return
    }
    if window.frame.origin != origin { savePosition(window, context: context, initialSize: initialSize) }
  }

  private static func focus(_ window: NSWindow) {
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Видимая область экрана, на котором стоит Лиза.
  private static func screenArea() -> NSRect {
    let main = NSApp.windows.first { $0 is MainFlutterWindow }
    let screen = main?.screen ?? NSScreen.main ?? NSScreen.screens.first
    return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
  }

  /// Не больше 90% экрана: на маленьком экране минимум иначе не влезает.
  private static func fit(_ size: NSSize, area: NSRect? = nil) -> NSSize {
    let area = area ?? screenArea()
    return NSSize(width: min(size.width, area.width * 0.9),
                  height: min(size.height, area.height * 0.9))
  }

  /// Большое окно по центру экрана, на котором стоит Лиза.
  private static func defaultFrame() -> NSRect {
    let area = screenArea()
    let size = NSSize(width: area.width * 0.9, height: area.height * 0.9)
    return NSRect(
      x: area.midX - size.width / 2, y: area.midY - size.height / 2,
      width: size.width, height: size.height)
  }
}
