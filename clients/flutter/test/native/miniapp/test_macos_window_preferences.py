"""Исполняет production Swift geometry/storage/gesture gate без Flutter.

AppKit wiring отдельно typecheck-ится со stubs только Flutter messenger API.
Это host-проверка, не native UI resize/mixed-DPI доказательство.
ledger:RL-miniapp-detached-window
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[5]
SOURCE = ROOT / 'clients/flutter/macos/Runner/MainFlutterWindow.swift'


class MacOSWindowPreferencesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = shutil.which('swiftc')
        if cls.compiler is None:
            raise unittest.SkipTest('Нужен macOS Swift compiler')
        source = SOURCE.read_text()
        cls.helpers = source.split('// BEGIN MINIAPP WINDOW PREFERENCES', 1)[1]
        cls.helpers = cls.helpers.split('\n', 1)[1].split('// END MINIAPP WINDOW PREFERENCES', 1)[0]

    def run_swift(self, main, arguments=()):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'main.swift'
            binary = Path(directory) / 'guard'
            source.write_text('import Cocoa\n' + self.helpers + '\n' + main)
            compiled = subprocess.run([self.compiler, str(source), '-o', str(binary)],
                                      capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            return subprocess.run([str(binary), *arguments], check=True,
                                  capture_output=True, text=True, timeout=15)

    def test_geometry_main_cap_minimum_origin_and_fallback(self):
        # AC:RL-miniapp-detached-window/53 AC:RL-miniapp-detached-window/58 AC:RL-miniapp-detached-window/59 — исполняется production frame().
        self.run_swift(r'''
let areas = [NSRect(x: 0, y: 25, width: 1440, height: 875),
             NSRect(x: -2560, y: 40, width: 2560, height: 1400),
             NSRect(x: 100, y: -1200, width: 3840, height: 2160),
             NSRect(x: 0, y: 0, width: 320, height: 250)]
for area in areas {
  for mainSize in [NSSize(width: 480, height: 520), NSSize(width: 960, height: 700),
                   NSSize(width: 300, height: 200), NSSize(width: 5000, height: 3000)] {
    let main = NSRect(x: area.minX - 150, y: area.minY + 30,
                      width: mainSize.width, height: mainSize.height)
    let cap = MiniAppWindowGeometry.available(main: main, area: area)
    let defaultFrame = MiniAppWindowGeometry.frame(preferred: nil, main: main, area: area)
    precondition(defaultFrame.size == cap)
    for preferred in [NSSize(width: 700, height: 620), NSSize(width: 1, height: 1),
                      NSSize(width: 9000, height: 5000), NSSize(width: CGFloat.infinity, height: 600)] {
      let frame = MiniAppWindowGeometry.frame(preferred: preferred, main: main, area: area)
      precondition(frame.width <= cap.width && frame.height <= cap.height)
      precondition(frame.minX >= area.minX && frame.maxX <= area.maxX)
      precondition(frame.minY >= area.minY && frame.maxY <= area.maxY)
      precondition(frame.width >= min(393, cap.width))
      precondition(frame.height >= min(520, cap.height))
    }
  }
}
let area = NSRect(x: -100, y: 20, width: 1800, height: 1000)
let main = NSRect(x: 120, y: 100, width: 1000, height: 800)
let frame = MiniAppWindowGeometry.frame(preferred: NSSize(width: 700, height: 620), main: main, area: area)
precondition(frame.midX == main.midX && frame.midY == main.midY)
// AC:RL-miniapp-detached-window/63 — минимум по ширине iPhone16, меньше нельзя.
let smallest = MiniAppWindowGeometry.frame(preferred: NSSize(width: 1, height: 1), main: main, area: area)
precondition(smallest.size == NSSize(width: 393, height: 520))
let fallback = MiniAppWindowGeometry.frame(preferred: nil, main: nil, area: area)
precondition(fallback.size == NSSize(width: 960, height: 700))
precondition(fallback.midX == area.midX && fallback.midY == area.midY)
''')

    def test_frame_stays_inside_visible_main_bounds(self):
        # AC:RL-miniapp-detached-window/60 — рамка, включая координаты.
        self.run_swift(r'''
let area = NSRect(x: 0, y: 25, width: 1512, height: 949)
for main in [NSRect(x: -221, y: 25, width: 1291, height: 891),
             NSRect(x: 442, y: 25, width: 1291, height: 891),
             NSRect(x: 100, y: -100, width: 1000, height: 800)] {
  let visibleMain = main.intersection(area)
  for preferred: NSSize? in [nil, NSSize(width: 1291, height: 891), NSSize(width: 700, height: 620)] {
    let frame = MiniAppWindowGeometry.frame(preferred: preferred, main: main, area: area)
    precondition(visibleMain.contains(frame), "Mini App вышел за видимую рамку Лизы")
  }
}
''')

    def test_position_persists_per_account_and_restores_relative_to_liza(self):
        # AC:RL-miniapp-detached-window/61
        self.run_swift(r'''
let suite = "liza.miniapp.position.test." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let prefs = MiniAppWindowPreferences(defaults: defaults)
let a = MiniAppGeometryContext(accountUserId: "@a:test", kind: "miniApp", generation: 1)
let b = MiniAppGeometryContext(accountUserId: "@b:test", kind: "miniApp", generation: 1)
let html = MiniAppGeometryContext(accountUserId: "@a:test", kind: "html", generation: 1)
let main = NSRect(x: -1400, y: 100, width: 1200, height: 800)
let chosen = NSRect(x: -900, y: 150, width: 700, height: 600)
let position = MiniAppWindowGeometry.position(frame: chosen, main: main)!
prefs.writePosition(account: a.accountUserId, position: position)
let reloaded = MiniAppWindowPreferences(defaults: UserDefaults(suiteName: suite)!)
precondition(reloaded.readPosition(a) == position)
precondition(reloaded.readPosition(b) == nil && reloaded.readPosition(html) == nil)
let area = NSRect(x: -1600, y: 0, width: 1600, height: 1000)
let restored = MiniAppWindowGeometry.frame(preferred: chosen.size,
  position: reloaded.readPosition(a), main: main, area: area)
precondition(restored == chosen, "ручная позиция должна восстановиться после закрытия")
let shifted = main.offsetBy(dx: 100, dy: 0)
let moved = MiniAppWindowGeometry.frame(preferred: chosen.size,
  position: reloaded.readPosition(a), main: shifted, area: area)
precondition(moved == chosen.offsetBy(dx: 100, dy: 0))
prefs.writePosition(account: a.accountUserId, position: NSPoint(x: CGFloat.nan, y: 0))
precondition(prefs.readPosition(a) == position)
''')

    def test_user_event_gate_account_generation_and_last_resize_wins(self):
        # AC:RL-miniapp-detached-window/54 AC:RL-miniapp-detached-window/55 AC:RL-miniapp-detached-window/56 AC:RL-miniapp-detached-window/57 AC:RL-miniapp-detached-window/59.
        self.run_swift(r'''
let suite = "liza.miniapp.test." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let preferences = MiniAppWindowPreferences(defaults: defaults)
let a = MiniAppGeometryContext(accountUserId: "@a:test", kind: "miniApp", generation: 1)
let b = MiniAppGeometryContext(accountUserId: "@b:test", kind: "miniApp", generation: 2)
let html = MiniAppGeometryContext(accountUserId: "@a:test", kind: "html", generation: 1)
let empty = MiniAppGeometryContext(accountUserId: "", kind: "miniApp", generation: 1)
let start = NSSize(width: 960, height: 700)
let chosen = NSSize(width: 730, height: 610)
let gate = MiniAppManualResize()
func begin(_ context: MiniAppGeometryContext = a, _ shown: Bool = true,
           _ mouse: Bool = true, _ applying: Bool = false) {
  gate.begin(context: context, size: start, normalShown: shown,
             mouseResize: mouse, applying: applying)
}
func finish(_ context: MiniAppGeometryContext = a, _ size: NSSize = chosen,
            _ shown: Bool = true, _ applying: Bool = false) -> Bool {
  if let completed = gate.finish(context: context, size: size, normalShown: shown, applying: applying) {
    preferences.write(account: completed.account, size: completed.size)
    return true
  }
  return false
}
precondition(!finish()) // move, close и present не имеют live capture.
for context in [html, empty] { begin(context); precondition(!finish(context)) }
begin(a, false); precondition(!finish()) // hidden creation.
begin(a, true, false); precondition(!finish()) // programmatic/zoom.
begin(a, true, true, true); precondition(!finish()) // apply geometry.
begin(); precondition(!finish(a, start)) // move/unchanged size.
begin(); precondition(!finish(a, chosen, false)) // hidden/minimized/fullscreen at end.
begin(); precondition(!finish(a, chosen, true, true))
begin(); gate.cancel(); precondition(!finish()) // screen/DPI or context change.
begin(); precondition(!finish(b))
begin(); precondition(!finish(MiniAppGeometryContext(accountUserId: a.accountUserId, kind: a.kind, generation: 2)))
precondition(preferences.read(a) == nil)
begin(); precondition(finish())
precondition(preferences.read(a) == chosen)
precondition(preferences.read(b) == nil && preferences.read(html) == nil && preferences.read(empty) == nil)
precondition(!finish()) // повторный end не пишет.
let small = MiniAppWindowGeometry.frame(preferred: preferences.read(a),
  main: NSRect(x: 0, y: 0, width: 480, height: 520),
  area: NSRect(x: 0, y: 0, width: 2000, height: 1200))
precondition(small.size == NSSize(width: 480, height: 520))
precondition(preferences.read(a) == chosen) // temporary clamp не пишет preference.
let reopened = MiniAppWindowGeometry.frame(preferred: preferences.read(a),
  main: NSRect(x: 0, y: 0, width: 1000, height: 800),
  area: NSRect(x: 0, y: 0, width: 2000, height: 1200))
precondition(reopened.size == chosen)
let secondWindow = MiniAppManualResize()
secondWindow.begin(context: a, size: start, normalShown: true, mouseResize: true, applying: false)
let newer = NSSize(width: 810, height: 660)
let completed = secondWindow.finish(context: a, size: newer, normalShown: true, applying: false)!
preferences.write(account: completed.account, size: completed.size)
gate.cancel() // закрытие старого окна не перетирает последнее ручное изменение.
precondition(preferences.read(a) == newer)
preferences.write(account: b.accountUserId, size: chosen)
precondition(preferences.read(a) == newer && preferences.read(b) == chosen)
preferences.write(account: a.accountUserId, size: NSSize(width: CGFloat.nan, height: 2))
precondition(preferences.read(a) == newer)
let key = "liza.miniapp.window.size.v1." + Data(a.accountUserId.utf8).base64EncodedString()
for invalid: [Double] in [[], [12], [-1, 600], [600, 0], [1, 2, 3]] {
  defaults.set(invalid, forKey: key)
  precondition(preferences.read(a) == nil)
}
''')

    def test_preferences_survive_new_process_and_reload(self):
        # AC:RL-miniapp-detached-window/54 AC:RL-miniapp-detached-window/61 — два настоящих процесса UserDefaults.
        suite = 'liza.miniapp.test.' + str(uuid.uuid4())
        harness = r'''
let suite = CommandLine.arguments[1]
let defaults = UserDefaults(suiteName: suite)!
let context = MiniAppGeometryContext(accountUserId: "@persist:test", kind: "miniApp", generation: 1)
let preferences = MiniAppWindowPreferences(defaults: defaults)
if CommandLine.arguments[2] == "write" {
  preferences.write(account: context.accountUserId, size: NSSize(width: 783, height: 642))
  preferences.writePosition(account: context.accountUserId, position: NSPoint(x: 0.8, y: 0.25))
  precondition(defaults.synchronize())
} else {
  defer { defaults.removePersistentDomain(forName: suite); defaults.synchronize() }
  precondition(preferences.read(context) == NSSize(width: 783, height: 642))
  let reloaded = MiniAppWindowPreferences(defaults: UserDefaults(suiteName: suite)!)
  precondition(reloaded.read(context) == NSSize(width: 783, height: 642))
  precondition(reloaded.readPosition(context) == NSPoint(x: 0.8, y: 0.25))
}
'''
        self.run_swift(harness, (suite, 'write'))
        self.run_swift(harness, (suite, 'read'))

    def test_appkit_large_frame_manual_shrink_and_minimum_policy_navigation(self):
        # AC:RL-miniapp-detached-window/54 AC:RL-miniapp-detached-window/57 AC:RL-miniapp-detached-window/58.
        # Настоящие AppKit frame/isZoomed/minSize и production plugin+observers.
        # Shown/active/live notifications/pointer event — синтетическая граница, не mouse UI tour.
        source = SOURCE.read_text()
        production = source[source.index('// BEGIN MINIAPP WINDOW PREFERENCES'):]
        stubs = self.flutter_stubs()
        harness = r'''
final class TestApplication {
  var windows: [NSWindow] = []
  var keyWindow: NSWindow?
  var currentEvent: NSEvent?
  var isActive = true
  func activate(ignoringOtherApps: Bool) {}
}
let NSApp = TestApplication()
final class TestWindow: NSWindow {
  override var isVisible: Bool { true }
}
extension MiniAppWindowPlugin {
  static func regression() {
    let realApplication = NSApplication.shared
    _ = realApplication // Создаём только hidden window; фокус не забираем.
    let area = NSScreen.main!.visibleFrame
    let suite = "liza.miniapp.test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = MiniAppWindowPreferences(defaults: defaults)
    let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    let registrar = FlutterPluginRegistrar()
    registrar.view = window.contentView
    let plugin = MiniAppWindowPlugin(registrar, preferences: prefs)
    NSApp.windows = [window]
    plugin.observeGeometry()
    let account = "@appkit:test"
    func title(_ kind: String, _ generation: Int) {
      let call = FlutterMethodCall()
      call.method = "setTitle"
      call.arguments = ["title": "test", "accountUserId": account,
                        "kind": kind, "geometryGeneration": generation]
      plugin.handle(call) { _ in }
    }
    title("miniApp", 1)
    window.setFrame(area, display: false)
    precondition(window.isZoomed, "AppKit large-frame heuristic repro")
    let context = plugin.geometryContext
    NSApp.currentEvent = NSEvent.mouseEvent(with: .leftMouseDown,
      location: NSPoint(x: 1, y: 1), modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 1,
      clickCount: 1, pressure: 1)
    precondition(NSApp.currentEvent?.window === window)
    let center = NotificationCenter.default
    center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
    window.setFrame(NSRect(origin: area.origin, size: NSSize(width: 700, height: 650)), display: false)
    center.post(name: NSWindow.didEndLiveResizeNotification, object: window)
    let chosen = window.frame.size
    precondition(prefs.read(context) == chosen, "first manual shrink must persist despite initial isZoomed")
    let next = MiniAppWindowGeometry.frame(preferred: prefs.read(context), main: area, area: area)
    precondition(next.size == chosen)

    // Native notification без mouse event не допускает программный resize.
    let mouseEvent = NSApp.currentEvent
    NSApp.currentEvent = nil
    center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
    window.setFrame(NSRect(origin: area.origin, size: NSSize(width: 740, height: 660)), display: false)
    center.post(name: NSWindow.didEndLiveResizeNotification, object: window)
    precondition(prefs.read(context) == chosen)
    NSApp.currentEvent = mouseEvent
    // Toggle отменяет уже начатый gesture до программного zoom/restore.
    center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
    let toggle = FlutterMethodCall()
    toggle.method = "toggleMaximize"
    plugin.handle(toggle) { _ in }
    center.post(name: NSWindow.didEndLiveResizeNotification, object: window)
    precondition(prefs.read(context) == chosen)

    window.setFrame(NSRect(origin: area.origin, size: NSSize(width: 900, height: 700)), display: false)
    let before = window.frame
    title("html", 2)
    precondition(window.minSize == NSSize(width: min(800, area.width * 0.9),
                                          height: min(600, area.height * 0.9)))
    precondition(window.frame == before, "kind navigation must not replace frame")
    title("miniApp", 3)
    precondition(window.minSize == NSSize(width: 393, height: 520))
    precondition(window.frame == before)
    title("miniApp", 4) // same-account deep-link не делает placement.
    precondition(window.frame == before)
    let tinyArea = NSRect(x: 0, y: 0, width: 300, height: 250)
    plugin.applyMinimum(window, area: tinyArea)
    precondition(window.minSize == tinyArea.size)
    precondition(window.frame == before)
    window.minSize = NSSize(width: 1500, height: 1000)
    center.post(name: NSWindow.didChangeScreenNotification, object: window)
    precondition(window.minSize == NSSize(width: 393, height: 520), "screen change must refresh minimum")
    precondition(prefs.read(context) == chosen, "navigation/screen fit must not overwrite preference")
  }
}
MiniAppWindowPlugin.regression()
'''
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'main.swift'
            binary = Path(directory) / 'guard'
            file.write_text(stubs + production + harness)
            compiled = subprocess.run([self.compiler, str(file), '-o', str(binary)],
                                      capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    @staticmethod
    def flutter_stubs():
        return r'''
import Cocoa
class MainFlutterWindow: NSWindow {}
typealias FlutterResult = (Any?) -> Void
let FlutterMethodNotImplemented = NSObject()
class FlutterError: NSObject {
  init(code: String, message: String?, details: Any?) {}
}
protocol FlutterPlugin {}
class FlutterMethodCall { var method = ""; var arguments: Any? }
class FlutterMethodChannel {
  init(name: String, binaryMessenger: NSObject) {}
  func invokeMethod(_ method: String, arguments: Any?) {}
}
class FlutterPluginRegistrar {
  var view: NSView?; var messenger = NSObject()
  func addMethodCallDelegate(_ plugin: MiniAppWindowPlugin, channel: FlutterMethodChannel) {}
}
'''

    def test_present_corrects_show_time_origin_shift(self):
        # AC:RL-miniapp-detached-window/60 — production present после сдвига AppKit.
        source = SOURCE.read_text()
        production = source[source.index('// BEGIN MINIAPP WINDOW PREFERENCES'):]
        harness = r'''
final class TestApplication {
  var windows: [NSWindow] = []
  var keyWindow: NSWindow?
  var isActive = true
  var currentEvent: NSEvent?
  func activate(ignoringOtherApps: Bool) {}
}
let NSApp = TestApplication()
final class ShiftOnShowWindow: NSWindow {
  var dragTarget: NSPoint?
  override var isVisible: Bool { true }
  override func performDrag(with event: NSEvent) {
    if let target = dragTarget { setFrameOrigin(target) }
  }
  override func makeKeyAndOrderFront(_ sender: Any?) {
    setFrameOrigin(NSPoint(x: frame.minX + 221, y: frame.minY))
  }
}
extension MiniAppWindowPlugin {
  static func regression() {
    _ = NSApplication.shared
    let area = NSScreen.main!.visibleFrame
    let main = MainFlutterWindow(contentRect: area, styleMask: [.titled, .resizable],
      backing: .buffered, defer: false)
    let mainFrame = NSRect(x: area.minX + 50, y: area.minY + 50,
      width: min(900, area.width - 100), height: min(650, area.height - 100))
    main.setFrame(mainFrame, display: false)
    let child = ShiftOnShowWindow(contentRect: mainFrame, styleMask: [.titled, .resizable],
      backing: .buffered, defer: false)
    let registrar = FlutterPluginRegistrar()
    registrar.view = child.contentView
    let suite = "liza.miniapp.show.test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let plugin = MiniAppWindowPlugin(registrar, preferences: MiniAppWindowPreferences(defaults: defaults))
    NSApp.windows = [main, child]
    let call = FlutterMethodCall()
    call.method = "present"
    call.arguments = ["title": "test", "accountUserId": "@show:test",
      "kind": "miniApp", "geometryGeneration": 1, "frameless": true]
    plugin.handle(call) { _ in }
    let expected = MiniAppWindowGeometry.frame(preferred: nil, main: main.frame, area: area)
    precondition(child.frame == expected, "показ сдвинул окно за рамку Лизы")
    // AC:RL-miniapp-detached-window/61 — production startDrag → новый plugin present.
    let chosenSize = NSSize(width: min(700, main.frame.width - 50),
                            height: min(550, main.frame.height - 50))
    child.setFrame(NSRect(origin: main.frame.origin, size: chosenSize), display: false)
    let chosen = NSRect(x: main.frame.maxX - chosenSize.width,
                        y: main.frame.minY + 20, width: chosenSize.width, height: chosenSize.height)
    child.dragTarget = chosen.origin
    NSApp.currentEvent = NSEvent.mouseEvent(with: .leftMouseDown,
      location: NSPoint(x: 1, y: 1), modifierFlags: [], timestamp: 0,
      windowNumber: child.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
    let drag = FlutterMethodCall()
    drag.method = "startDrag"
    plugin.handle(drag) { _ in }
    let context = plugin.geometryContext
    precondition(plugin.preferences.read(context) == nil, "move-only не переписывает размер")
    precondition(plugin.preferences.readPosition(context) ==
      MiniAppWindowGeometry.position(frame: chosen, main: main.frame), "ручная позиция потеряна")
    plugin.preferences.write(account: context.accountUserId, size: chosenSize)
    let reopened = ShiftOnShowWindow(contentRect: main.frame, styleMask: [.titled, .resizable],
      backing: .buffered, defer: false)
    let nextRegistrar = FlutterPluginRegistrar()
    nextRegistrar.view = reopened.contentView
    let next = MiniAppWindowPlugin(nextRegistrar,
      preferences: MiniAppWindowPreferences(defaults: UserDefaults(suiteName: suite)!))
    NSApp.windows = [main, reopened]
    next.handle(call) { _ in }
    precondition(reopened.frame == chosen, "новое окно не восстановило ручную позицию")
    let savedPosition = next.preferences.readPosition(context)
    reopened.setFrameOrigin(main.frame.origin)
    let staleGeneration = next.moveGeneration
    next.observeGeometry()
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification,
                                    object: NSApplication.shared)
    next.finishManualMove(reopened, context: context,
      origin: chosen.origin, generation: staleGeneration)
    precondition(next.preferences.readPosition(context) == savedPosition,
                 "старое завершение после deactivate не должно менять позицию")
    let wrongContext = MiniAppGeometryContext(accountUserId: "@other:test", kind: "miniApp", generation: 1)
    next.finishManualMove(reopened, context: wrongContext,
      origin: chosen.origin, generation: next.moveGeneration)
    precondition(next.preferences.readPosition(wrongContext) == nil)


  }
}
MiniAppWindowPlugin.regression()
'''
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'main.swift'
            binary = Path(directory) / 'guard'
            # Контроль RED: тот же production present без коррекции после показа.
            for corrected in (False, True):
                body = production if corrected else production.replace(
                    'window.setFrameOrigin(frame.origin)', '_ = frame.origin')
                file.write_text(self.flutter_stubs() + body + harness)
                compiled = subprocess.run([self.compiler, str(file), '-o', str(binary)],
                                          capture_output=True, text=True, timeout=60)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
                if corrected:
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                else:
                    self.assertNotEqual(run.returncode, 0, 'Страж пропустил сдвиг при показе')

    def test_production_appkit_wiring_typechecks(self):
        source = SOURCE.read_text()
        production = source[source.index('// BEGIN MINIAPP WINDOW PREFERENCES'):]
        stubs = self.flutter_stubs()
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'wiring.swift'
            file.write_text(stubs + production)
            run = subprocess.run([self.compiler, '-typecheck', str(file)],
                                 capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stderr)


if __name__ == '__main__':
    unittest.main()
