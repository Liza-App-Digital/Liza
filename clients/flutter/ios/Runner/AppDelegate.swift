import UIKit
import Flutter
import BackgroundTasks
import UserNotifications
import flutter_foreground_task
import receive_sharing_intent

/// Заглушка `flutter_foreground_task` на iOS (жалоба 2026-09-22: «Сбой приложения»
/// при каждом сворачивании, сборки 3764/3765). Плагин регистрирует обработчик
/// BGTask в `didFinishLaunching`, которого под нашими сценами не получает, а в
/// `applicationDidEnterBackground` делает `BGTaskScheduler.submit` — без
/// регистрации это ObjC-исключение мимо Swift `do/catch`. На холодном старте по
/// ссылке движок шлёт ему `didFinishLaunching` после окончания запуска — там
/// падает уже `register`. Объявленный «сценовым», плагин выпадает из всех
/// fallback-путей движка (`pluginSupportsSceneLifecycle` = `conformsToProtocol:`).
/// На iOS он нам не нужен: сервис запускается только на Android (`dialer.dart`).
/// Идентификатор в `BGTaskSchedulerPermittedIdentifiers` НЕ убирать: если плагины
/// снова начнут получать `didFinishLaunching` вовремя, `register` на
/// неразрешённый id уронит приложение на старте. Снять заглушку, когда плагин
/// сам перейдёт на `FlutterSceneLifeCycleDelegate`.
extension SwiftFlutterForegroundTaskPlugin: @retroactive FlutterSceneLifeCycleDelegate {}

/// Делегат сцены. С iOS 27 приложение, собранное свежим SDK без scene-based
/// жизненного цикла, UIKit не запускает вовсе (заявка №34: падение в
/// `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` ещё до
/// первого кадра). Класс лежит в этом файле намеренно: `AppDelegate.swift` уже
/// в таргете, а `project.pbxproj` патчит `apply-account-profile.sh` —
/// отдельный файл пришлось бы вносить туда же. Явного `@objc(имя)` нет
/// намеренно: в манифесте сцены класс указан как `$(PRODUCT_MODULE_NAME).SceneDelegate`
/// (связка шаблона Flutter), а явное ObjC-имя это имя бы сменило.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // Контроллер создаём САМИ (в манифесте сцены нет `UISceneStoryboardFile`):
    // его инициализация поднимает движок и регистрирует плагины, а те требуют
    // готовое окно — см. `LizaPluginRegistrant`. Дальше `super` увидит окно с
    // контроллером и перенесёт его в окно этой сцены (`moveRootViewControllerFrom`).
    let appDelegate = UIApplication.shared.delegate as? AppDelegate
    if appDelegate?.window == nil {
      appDelegate?.connectingWindowScene = scene as? UIWindowScene
      _ = FlutterViewController(project: nil, nibName: nil, bundle: nil)
      appDelegate?.connectingWindowScene = nil
    }
    // Холодный старт по ссылке «Поделиться» (см. `handleShareMediaURL`).
    for context in connectionOptions.urlContexts {
      LizaShareMedia.handle(context.url, initial: true)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      LizaShareMedia.handle(context.url, initial: false)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }
}

/// Приём ссылки `ShareMedia-<bundleId>:share` от расширения «Liza Share».
/// Под сценами iOS отдаёт схему URL в НИЖНЕМ регистре (`sharemedia-…`), а
/// `receive_sharing_intent` сверяет префикс с учётом регистра
/// (`hasMatchingSchemePrefix`) — и молча отбрасывает ссылку: после «Опубликовать»
/// в Лизе открывался просто список чатов, медиа до Dart не доходило (жалоба
/// 2026-11-05, сборки ≥3766, начиная с перехода на UIScene). Возвращаем схеме
/// регистр, который ждёт плагин, и вызываем его напрямую — его собственный
/// путь через fallback движка этот префикс больше не пропустит.
enum LizaShareMedia {
  static func handle(_ url: URL, initial: Bool) {
    guard let bundleId = Bundle.main.bundleIdentifier,
      let scheme = url.scheme,
      scheme.caseInsensitiveCompare("\(kSchemePrefix)-\(bundleId)") == .orderedSame,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return }
    components.scheme = "\(kSchemePrefix)-\(bundleId)"
    guard let fixed = components.url else { return }
    let plugin = SwiftReceiveSharingIntentPlugin.instance
    if initial {
      _ = plugin.application(UIApplication.shared, didFinishLaunchingWithOptions: [UIApplication.LaunchOptionsKey.url: fixed])
    } else {
      _ = plugin.application(UIApplication.shared, open: fixed, options: [:])
    }
  }
}

/// Регистрация плагинов. Живёт здесь, а не в `didInitializeImplicitFlutterEngine`,
/// из-за порядка запуска под сценами: на момент того колбэка окон не существует
/// вовсе (замер на симуляторе iOS 27: `scenes=1 windows=0`), а `flutter_contacts`
/// в `register(with:)` делает `delegate!.window!!.rootViewController!` —
/// форс-анврап, то есть падение приложения прямо на регистрации. `open_app_file`
/// мягче, но запоминает nil-контроллер и потом молча не открывает файлы из чата.
///
/// На этом пути Flutter отдаёт сам `FlutterViewController` — значит окно можно
/// собрать вокруг него ДО регистрации. Плагины `application(_:didFinishLaunchingWithOptions:)`
/// НЕ получают: отложенную пересылку движок делает только контроллеру из
/// сториборда (`awokenFromNib`), а наш создан в коде. Холодный старт по ссылке
/// приходит плагинам через `sceneWillConnectFallback` уже ПОСЛЕ окончания
/// запуска — см. заглушку `SwiftFlutterForegroundTaskPlugin` ниже.
@objc class LizaPluginRegistrant: NSObject, FlutterPluginRegistrant {
  func register(with registry: FlutterPluginRegistry) {
    if let viewController = registry as? FlutterViewController {
      (UIApplication.shared.delegate as? AppDelegate)?.adoptWindow(for: viewController)
    }

    GeneratedPluginRegistrant.register(with: registry)

    // Register our native APNs plugin
    if let registrar = registry.registrar(forPlugin: "ApnsPushPlugin") {
      ApnsPushPlugin.register(with: registrar)
    }

    // Защита экрана канала (запрет копирования): на iOS доступно только
    // скрытие содержимого в переключателе приложений — см. SecureScreenPlugin.
    if let registrar = registry.registrar(forPlugin: "SecureScreenPlugin") {
      SecureScreenPlugin.register(with: registrar)
    }

    // Чтение нескольких изображений из буфера (вставка альбома по Cmd/Ctrl+V).
    if let registrar = registry.registrar(forPlugin: "ClipboardImagesPlugin") {
      ClipboardImagesPlugin.register(with: registrar)
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// Сцена, которая подключается прямо сейчас. Ставит `SceneDelegate` на время
  /// создания контроллера: `connectedScenes` в этот момент не надёжен (может
  /// быть пуст или содержать не ту сцену), а движок Flutter в той же точке
  /// берёт именно подключаемую сцену.
  var connectingWindowScene: UIWindowScene?

  /// Окно с корневым контроллером до регистрации плагинов (см.
  /// `LizaPluginRegistrant`). Окно временное: `FlutterSceneDelegate` при
  /// подключении сцены создаст окно сцены, перенесёт в него контроллер и
  /// переприсвоит `window` — так что после старта `delegate.window` указывает
  /// на настоящее окно, и плагины, читающие его позже, видят актуальное.
  func adoptWindow(for viewController: UIViewController) {
    guard window == nil else { return }
    guard let windowScene = connectingWindowScene ?? UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene }).first
    else {
      // Без окна flutter_contacts упадёт на регистрации следующей строкой —
      // пусть в логе будет причина, а не безымянный форс-анврап.
      NSLog("Liza: нет UIWindowScene для окна до регистрации плагинов")
      return
    }
    let sceneWindow = UIWindow(windowScene: windowScene)
    sceneWindow.rootViewController = viewController
    window = sceneWindow
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    pluginRegistrant = LizaPluginRegistrant()

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // Set ourselves as the notification center delegate AFTER super.application
    // to ensure FlutterAppDelegate doesn't override our delegate.
    UNUserNotificationCenter.current().delegate = self

    registerReadBannerRefresh()

    return result
  }

  // MARK: - Р2 L2: фоновая чистка прочитанных баннеров (BGAppRefresh)

  /// Идентификатор = bundle id: он уже разрешён в `BGTaskSchedulerPermittedIdentifiers`
  /// как `$(PRODUCT_BUNDLE_IDENTIFIER)` и меняется вместе с Apple-аккаунтом.
  private var readBannerRefreshId: String? { Bundle.main.bundleIdentifier }

  /// `register` обязан пройти до конца `didFinishLaunching` (иначе ObjC-исключение
  /// на `submit`). `submit` — на уходе в фон через уведомление: под сценами
  /// `applicationDidEnterBackground` делегату приложения не приходит.
  private func registerReadBannerRefresh() {
    guard let id = readBannerRefreshId else { return }
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) {
      [weak self] task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self?.handleReadBannerRefresh(refresh)
    }
    guard registered else {
      NSLog("Liza: BGAppRefresh %@ не зарегистрирован", id)
      return
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.scheduleReadBannerRefresh()
    }
  }

  private func scheduleReadBannerRefresh() {
    guard let id = readBannerRefreshId else { return }
    let request = BGAppRefreshTaskRequest(identifier: id)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      NSLog("Liza: BGAppRefresh submit: %@", String(describing: error))
    }
  }

  /// Тот же проход, что NSE делает на каждом пуше, — по каждому аккаунту.
  /// Пустой `client_names` (старая установка) → один проход по легаси-ключам.
  private func handleReadBannerRefresh(_ task: BGAppRefreshTask) {
    scheduleReadBannerRefresh()
    let defaults = UserDefaults(suiteName: lizaAppGroup())
    let names: [String?] = {
      let list = defaults?.stringArray(forKey: "client_names") ?? []
      return list.isEmpty ? [nil] : list.map { Optional($0) }
    }()
    let group = DispatchGroup()
    let finished = ReadBannerSweep.Once { removed in
      task.setTaskCompleted(success: removed >= 0)
    }
    task.expirationHandler = { finished.call(-1) }
    var total = 0
    let lock = NSLock()
    for name in names {
      group.enter()
      ReadBannerSweep.run(clientName: name, defaults: defaults) { removed in
        lock.lock(); total += removed; lock.unlock()
        group.leave()
      }
    }
    group.notify(queue: .global()) {
      NSLog("Liza: BGAppRefresh снял прочитанных баннеров: %d", total)
      finished.call(total)
    }
  }

  // Handle notification presentation when app is in foreground.
  // For remote push (from NSE): show banner + sound + badge.
  // For local notifications (from flutter_local_notifications): forward to super
  // which reads presentSound/presentAlert from DarwinNotificationDetails.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    let isRemote = notification.request.trigger is UNPushNotificationTrigger
    let appActive = UIApplication.shared.applicationState == .active
    switch PushPresentation.decide(
      userInfo: userInfo,
      isRemote: isRemote,
      appActive: appActive,
      inActiveRoom: appActive && ApnsPushPlugin.isActiveRoom(userInfo)
    ) {
    case .suppress:
      completionHandler([])
      return
    case .show:
      // Remote push from NSE — explicitly show with sound, banner, badge.
      if #available(iOS 14.0, *) {
        completionHandler([.banner, .sound, .badge, .list])
      } else {
        completionHandler([.alert, .sound, .badge])
      }
      return
    case .plugin:
      break
    }

    // Local notification from flutter_local_notifications — let the plugin decide.
    super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
  }

  // Forward APNs token to our plugin
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    ApnsPushPlugin.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  // Forward APNs registration failure
  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    ApnsPushPlugin.didFailToRegisterForRemoteNotifications(error: error)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  // Forward incoming remote notifications to Flutter for data sync.
  // NSE already handles showing the notification — we only forward to Flutter
  // so pushHelper can process the event (haptic, badge sync, etc.).
  // In foreground: NSE notification is displayed via willPresent above,
  // and pushHelper adds haptic feedback.
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    // Тихий «почисти шторку»: фоновое окно держим до ответа Dart (≤25 с).
    if ApnsPushPlugin.isClearingPush(userInfo) {
      ApnsPushPlugin.handleClearingPush(
        userInfo: userInfo, completionHandler: completionHandler)
      return
    }
    ApnsPushPlugin.didReceiveRemoteNotification(userInfo: userInfo)
    completionHandler(.newData)
  }

  // Handle user tapping on a notification (both local and remote).
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo

    // Remote notification from NSE — forward tap to our APNs plugin.
    if userInfo["room_id"] != nil {
      ApnsPushPlugin.didReceiveNotificationTap(userInfo: userInfo)
    }

    // Always call super so flutter_local_notifications can handle its own notifications.
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }
}
