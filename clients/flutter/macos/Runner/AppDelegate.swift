import Cocoa
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate {
  /// Токен активности против App Nap. macOS усыпляет приложение, окно которого
  /// ПЕРЕКРЫТО другими (не «потеряло фокус»): long-poll `/sync` встаёт на
  /// минуты, а с ним — локальное уведомление из `onNotification`, наша
  /// единственная страховка от медленного APNs (`pushes.md` §18.2 п.1, §18.6b).
  ///
  /// Замер 2026-09-17 (заявка №31): у пользователя `/sync` мёртв 104 мин из 138
  /// (10 провалов 2–16 мин, все при не-frontmost окне), при этом реакция клиента
  /// на пуш, прилетевший в тишину, — медиана 4 мин 42 с. То есть 75 % времени
  /// работал только медленный путь APNs — это и есть его «стабильно 2–4 минуты».
  /// У владельца в том же окне 0 провалов (его окно видимо) и баннер из /sync за
  /// 0,2 с — отсюда асимметрия, из-за которой класс дважды закрывали как
  /// «безвредный».
  ///
  /// ⚠️ Опция ровно одна и менять её нельзя:
  /// - `.userInitiatedAllowingIdleSystemSleep` снимает App Nap и **не мешает**
  ///   Маку засыпать по бездействию;
  /// - `.background` App Nap НЕ снимает (наоборот, подтверждает фоновость);
  /// - `.userInitiated` держал бы систему от сна — «ноутбук не засыпает».
  /// Гейта по логину нет намеренно: без залогиненного клиента sync-цикла нет,
  /// будить нечего, а гейт вводит зависимость от порядка «регистрация плагина ⇄
  /// событие логина» с режимом отказа «активность не началась никогда».
  private var appNapActivity: NSObjectProtocol?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationWillTerminate(_ notification: Notification) {
    if let activity = appNapActivity {
      ProcessInfo.processInfo.endActivity(activity)
      appNapActivity = nil
    }
    super.applicationWillTerminate(notification)
  }

  /// LABA-2238: строка-по-типу для медиа-сообщения без подписи. Сервер (Sygnal)
  /// НЕ шлёт `body`, если это имя файла — иначе в баннере светился бы
  /// `recording…ogg` вместо «🎤 Голосовое сообщение».
  static func mediaTypeLabel(_ msgtype: String?, isVoice: Bool) -> String? {
    switch msgtype {
    case "m.image":
      return String(localized: "🖼 Фото", comment: "Push banner: image message")
    case "m.video":
      return String(localized: "🎬 Видео", comment: "Push banner: video message")
    case "m.file":
      return String(localized: "📎 Файл", comment: "Push banner: file message")
    case "m.sticker":
      return String(localized: "Стикер", comment: "Push banner: sticker message")
    case "m.audio":
      return isVoice
        ? String(localized: "🎤 Голосовое сообщение", comment: "Push banner: voice message")
        : String(localized: "🎤 Аудио", comment: "Push banner: audio message")
    default:
      return nil
    }
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    // media_kit (libmpv) на КАЖДЫЙ Player.open() пишет playlist-файл через
    // Dart `Directory.systemTemp` и зовёт mpv `loadlist`. Вне launchd-контекста
    // (запуск из терминала/Xcode, после переноса из /Applications, quarantine)
    // TMPDIR может оказаться `/tmp`, куда App Sandbox запрещает запись → temp
    // молча не создаётся (ошибку глотает safe_local_storage) → mpv `loadlist
    // /tmp/<uuid>: No such file` → НЕ воспроизводится НИ ОДНО видео (stream,
    // локальный файл, E2EE-фолбэк — см. лог 2026-07-22/08-19).
    // NSTemporaryDirectory() под sandbox возвращает контейнерный `Data/tmp`
    // (запись разрешена). `Directory.systemTemp` — статический геттер, читает
    // getenv("TMPDIR") свежим при каждом обращении → setenv здесь (до первого
    // open по тапу) гарантированно подхватывается. Идемпотентно: при верном
    // TMPDIR (launchd-запуск) overwrite не меняет значение.
    setenv("TMPDIR", NSTemporaryDirectory(), 1)
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Держим процесс вне App Nap на всё время жизни: иначе при перекрытом окне
    // /sync замирает на минуты и уведомление начинает зависеть только от APNs
    // (разбор — у поля `appNapActivity`).
    appNapActivity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "Matrix /sync long-poll: уведомления без ожидания APNs"
    )

    // Register the macOS APNs plugin with the Flutter engine.
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      MacApnsPushPlugin.register(
        with: controller.registrar(forPlugin: "MacApnsPushPlugin")
      )

      // Защита экрана канала (запрет копирования): на macOS доступно только
      // исключение окна из захвата и накладка в фоне — см. SecureScreenPlugin.
      SecureScreenPlugin.register(
        with: controller.registrar(forPlugin: "SecureScreenPlugin"),
        window: mainFlutterWindow
      )

      // Чтение нескольких изображений из буфера (вставка альбома по Cmd/Ctrl+V).
      ClipboardImagesPlugin.register(
        with: controller.registrar(forPlugin: "ClipboardImagesPlugin")
      )

      // Канал для вывода окна на передний план. При открытии по deep-link
      // (liza://invite/...) из браузера приложение получает ссылку через
      // app_links, но окно НЕ выходит вперёд (процесс остаётся позади
      // браузера). Flutter, обработав invite-ссылку, дёргает этот метод.
      let windowChannel = FlutterMethodChannel(
        name: "liza/macos_window",
        binaryMessenger: controller.engine.binaryMessenger
      )
      windowChannel.setMethodCallHandler { [weak self] call, result in
        if call.method == "bringToFront" {
          self?.bringWindowToFront()
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    // Set ourselves as UNUserNotificationCenter delegate for notification tap handling.
    UNUserNotificationCenter.current().delegate = self
  }

  /// Выводит главное окно на передний план и активирует приложение.
  private func bringWindowToFront() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = mainFlutterWindow {
      if window.isMiniaturized {
        window.deminiaturize(self)
      }
      window.makeKeyAndOrderFront(self)
    }
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      bringWindowToFront()
    }
    return true
  }

  override func applicationDidBecomeActive(_ notification: Notification) {
    if let window = mainFlutterWindow, !window.isVisible {
      if window.isMiniaturized {
        window.deminiaturize(self)
      }
      window.makeKeyAndOrderFront(self)
    }
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // MARK: - APNs callbacks

  override func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    MacApnsPushPlugin.didRegisterForRemoteNotifications(deviceToken: deviceToken)
  }

  override func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    MacApnsPushPlugin.didFailToRegisterForRemoteNotifications(error: error)
  }

  override func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
    MacApnsPushPlugin.didReceiveRemoteNotification(userInfo: userInfo)
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// Тап по уведомлению — и по нативному (APNs), и по локальному (Dart).
  /// Делегатом центра остаётся AppDelegate (он перетирает делегат плагина
  /// flutter_local_notifications при регистрации), поэтому плагинный обработчик
  /// на macOS не вызывается НИКОГДА — без этого метода тап уходил бы в никуда.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    MacApnsPushPlugin.didReceiveNotificationTap(
      userInfo: response.notification.request.content.userInfo
    )
    bringWindowToFront()
    completionHandler()
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if notification.request.trigger is UNPushNotificationTrigger {
      // For remote (APNs) push notifications: format the content natively
      // (like a mini-NSE) so the user sees proper text instead of raw loc-keys.
      // Flutter's pushHelper skips showing a local notification on macOS.
      let userInfo = notification.request.content.userInfo
      let mutableContent = notification.request.content.mutableCopy() as! UNMutableNotificationContent

      let senderName = userInfo["sender_display_name"] as? String
      let roomName = userInfo["room_name"] as? String
      let eventType = userInfo["type"] as? String

      // Try to get message body from the nested "content" dict.
      // LABA-2238: у медиа сервер шлёт `body` ТОЛЬКО если это реальная подпись;
      // для медиа-фолбэка (body == имя файла) body нет, тип берём из `msgtype`.
      var messageBody: String? = nil
      var msgtype: String? = nil
      var isVoice = false
      if let contentDict = userInfo["content"] as? [String: Any] {
          messageBody = contentDict["body"] as? String
          msgtype = contentDict["msgtype"] as? String
          isVoice = (contentDict["voice"] as? Bool) ?? false
      }
      if msgtype == nil, let contentString = userInfo["content"] as? String,
         let contentData = contentString.data(using: .utf8),
         let contentDict = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] {
          messageBody = contentDict["body"] as? String
          msgtype = contentDict["msgtype"] as? String
          isVoice = (contentDict["voice"] as? Bool) ?? false
      }

      let isEncrypted = eventType == "m.room.encrypted"
      let isInvite = eventType == "m.room.member"
      let isGroupChat = roomName != nil && !roomName!.isEmpty

      // LABA-2238: медиа без подписи → строка-по-типу вместо имени файла.
      if !isEncrypted, messageBody == nil,
         let label = Self.mediaTypeLabel(msgtype, isVoice: isVoice) {
          messageBody = label
      }

      if isInvite {
          mutableContent.title = senderName ?? "Someone"
          if isGroupChat {
              mutableContent.body = "\(senderName ?? "Someone") invited you to \(roomName!)"
          } else {
              mutableContent.body = "\(senderName ?? "Someone") invited you to chat"
          }
      } else if let sender = senderName {
          if isGroupChat {
              mutableContent.title = roomName!
              if let body = messageBody, !isEncrypted {
                  mutableContent.body = "\(sender): \(body)"
              } else {
                  mutableContent.body = "\(sender) sent a message"
              }
          } else {
              mutableContent.title = sender
              if let body = messageBody, !isEncrypted {
                  mutableContent.body = body
              } else {
                  mutableContent.body = "\(sender) sent a message"
              }
          }
      }

      mutableContent.sound = UNNotificationSound(named: UNNotificationSoundName("liza_ding.aiff"))

      // Бейдж — из КЛИЕНТ-авторитетного числа в App Group (его пишет Dart на
      // каждый sync), а НЕ из сырого серверного counts.unread: последнее считает
      // topology-скрытые/server-stuck комнаты, которые клиент исключает →
      // накопительная инфляция. willPresent работает при живом приложении, так
      // что App Group свежий. Пусто/0 → 1 (нижняя граница). Ставим РОВНО число,
      // без инкремента. См. RL-app-badge-native-visible-count.
      let badgeDefaults = UserDefaults(suiteName: lizaAppGroup())
      let savedBadge = badgeDefaults?.object(forKey: "badge_count") as? Int
      mutableContent.badge = NSNumber(value: (savedBadge ?? 0) > 0 ? savedBadge! : 1)

      // userInfo во Flutter здесь НЕ передаём: `application(_:didReceiveRemoteNotification:)`
      // получает тот же пуш на приходе всегда, а этот делегат — только у активного
      // приложения; второй вызов давал двойной `onMessage` (заявка №31, 2026-09-17).

      // ⚠️ Этот делегат macOS зовёт ТОЛЬКО когда Liza — активное (frontmost)
      // приложение. Когда пользователь работает в другом окне, система показывает
      // APNs-оригинал сама, сюда не заходя, — поэтому гейт ниже закрывает лишь
      // активное состояние; для неактивного опоздавший баннер снимает Dart через
      // `retractDelivered` после решения на приходе пуша.
      //
      // Опоздавший пуш (APNs держит его, пока NAT-сессия простаивает: жалоба
      // 2026-09-16 — 7,5 мин «в хранилище») может приехать, когда сообщение уже
      // прочитано ЛИБО уже показано локальным уведомлением из /sync. Спрашиваем
      // живой Flutter — он единственный знает ресипты и свои баннеры. Fail-open:
      // молчание/ошибка → показываем (баннер не теряем, инвариант LABA-2354).
      MacApnsPushPlugin.shouldSuppressBanner(userInfo) { [weak self] gate in
        guard let self = self else { return completionHandler([]) }
        if gate == .suppress {
          completionHandler([])
          return
        }
        self.presentRemoteNotification(
          notification: notification,
          content: mutableContent,
          userInfo: userInfo,
          center: center,
          pushAheadOfSync: gate == .banner,
          completionHandler: completionHandler
        )
      }
    } else {
      // Локальные уведомления (созданы Flutter) — показываем как есть.
      completionHandler([.banner, .sound, .badge, .list])
    }
  }

  /// Показ нативного баннера по APNs-пушу (вынесено из `willPresent`, чтобы
  /// вызываться уже ПОСЛЕ ответа гейта подавления).
  ///
  /// Развилка по фактическому статусу приложения:
  /// - app active (окно ключевое): баннер по неоткрытому чату рисует локальный
  ///   путь из /sync — системный дал бы второй. Подавляем баннер, но звук, запись
  ///   в Notification Center и бейдж разрешаем. Исключение — [pushAheadOfSync]:
  ///   пуш обогнал sync, Dart закрыл локальный путь по этому событию, и без
  ///   `.banner` здесь баннера не было бы вовсе (разбор 2026-09-28, §22).
  /// - app inactive/visible (окно потеряло фокус, другое приложение поверх,
  ///   Cmd-Tab, в Dock): показываем нативный баннер с локализованным текстом.
  ///
  /// ⚠️ LABA-2354 — фикс гонки «пуши не приходят на macOS в фоне». РАНЬШЕ код
  /// сразу и безусловно гасил оригинал (`completionHandler([])`), и лишь ПОТОМ
  /// асинхронно постил `.formatted`-копию через `center.add`. Между гашением
  /// оригинала и фактической постановкой replacement было окно гонки с
  /// APNs-очередью и системным дедупом — replacement иногда терялся, а оригинал
  /// уже погашен → тишина. Теперь оригинал подавляем ТОЛЬКО в completion-колбэке
  /// `add`, когда replacement гарантированно поставлен; при ошибке add
  /// показываем оригинал, чтобы баннер не пропал ни при каком исходе.
  private func presentRemoteNotification(
    notification: UNNotification,
    content mutableContent: UNMutableNotificationContent,
    userInfo: [AnyHashable: Any],
    center: UNUserNotificationCenter,
    pushAheadOfSync: Bool,
    completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
      if NSApp.isActive {
        // Чат открыт в видимом окне — сообщение уже на экране: ни звука, ни
        // записи в Notification Center (жалоба 2026-09-15 «пуш в активном чате»).
        // Свёрнутое/скрытое окно — прежнее поведение.
        if let window = mainFlutterWindow, window.isVisible, !window.isMiniaturized,
           MacApnsPushPlugin.isActiveRoom(userInfo) {
          completionHandler([])
          return
        }
        completionHandler(
          pushAheadOfSync ? [.banner, .sound, .list, .badge] : [.sound, .list, .badge]
        )
      } else {
        // На macOS 26 сюда не попасть: неактивному приложению `willPresent` не
        // вызывается (замер 2026-09-17, usernoted показывает оригинал с дефолтными
        // опциями). Ветка оставлена на случай иной семантики у старых macOS.
        // Локализованная замена title/body с другим identifier (избегаем
        // дедупа по исходному id).
        let newRequest = UNNotificationRequest(
          identifier: notification.request.identifier + ".formatted",
          content: mutableContent,
          trigger: nil
        )
        center.add(newRequest) { error in
          if let error = error {
            NSLog(
              "[LizaPush] Failed to add formatted notification, showing original: %@",
              error.localizedDescription
            )
            // Replacement не встал — показываем оригинал, чтобы не потерять баннер.
            completionHandler([.banner, .sound, .list, .badge])
          } else {
            // Replacement поставлен — оригинал подавляем (баннер придёт от него).
            completionHandler([])
          }
        }
      }
  }
}
