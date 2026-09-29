import Cocoa
import FlutterMacOS
import UserNotifications

/// App Group приложения, вычисленная из bundle id (зеркало `lizaAppGroup` из
/// iOS `ApnsPushPlugin`). Для расширений (NSE) bundle id несёт лишний последний
/// компонент — отбрасываем. Вычисляем, а не хардкодим: bundle id меняется при
/// смене Apple-аккаунта, рассинхрон с entitlements ломает App Group МОЛЧА.
func lizaAppGroup(for bundle: Bundle = .main) -> String {
    guard let bundleId = bundle.bundleIdentifier else { return "" }
    let isExtension = bundle.bundleURL.pathExtension == "appex"
    let appId = isExtension
        ? bundleId.split(separator: ".").dropLast().joined(separator: ".")
        : bundleId
    return "group.\(appId)"
}

/// Native APNs plugin for macOS — mirrors ApnsPushPlugin.swift from iOS.
/// Provides raw APNs device token (hex) via MethodChannel.
public class MacApnsPushPlugin: NSObject, FlutterPlugin {
    /// Serial queue protecting all mutable static state.
    private static let queue = DispatchQueue(label: "MacApnsPushPlugin")

    private static var channel: FlutterMethodChannel?
    private static var pendingToken: String?
    private static var pendingTokenResult: FlutterResult?
    /// Тап по баннеру до того, как Flutter создал канал (запуск приложения
    /// кликом по уведомлению после Cmd+Q) — зеркало iOS `pendingNotificationTap`.
    private static var pendingNotificationTap: [String: String]?
    static var activeRoomId: String?
    static var activeClientName: String?
    static var activeSingleClient = true

    /// Пуш пришёл в чат, открытый сейчас на экране (зеркало Dart
    /// `pushInActiveRoomFor`): тот же room_id у ДРУГОГО своего аккаунта не глушим;
    /// пуш без client_name (старый pusher) считаем своим только при одном аккаунте.
    static func isActiveRoom(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let room = activeRoomId,
              let pushRoom = userInfo["room_id"] as? String,
              pushRoom == room else { return false }
        if let pushClient = userInfo["client_name"] as? String, !pushClient.isEmpty {
            return pushClient == activeClientName
        }
        return activeSingleClient
    }

    /// Спросить у живого Flutter, не лишний ли этот баннер (событие уже показано
    /// локальным уведомлением ЛИБО уже прочитано — в том числе на другом
    /// устройстве). Состояние держит Dart: у натива нет ни таймлайна, ни
    /// ресиптов, а дублировать их значило бы завести второй источник правды.
    ///
    /// Ответ — имя `NativeBannerGate` из Dart (`apns_push_service.dart`):
    /// `suppress` / `banner` (пуш обогнал sync — баннер рисует натив) / `silent`.
    ///
    /// Fail-open по времени и по ошибке: нет канала / Flutter не ответил →
    /// `.silent`, т.е. не подавлять. Потерянный баннер хуже лишнего (инвариант
    /// LABA-2354). `.banner` на fail-open НЕ даём: неизвестно, обогнал ли пуш sync,
    /// а локальный баннер при этом не закрыт — вышло бы два.
    enum BannerGate: String {
        case suppress, banner, silent
    }

    static func shouldSuppressBanner(
        _ userInfo: [AnyHashable: Any],
        timeout: TimeInterval = 1.5,
        completion: @escaping (BannerGate) -> Void
    ) {
        let ch = queue.sync { channel }
        guard let ch = ch else { return completion(.silent) }
        var payload: [String: Any] = [:]
        for key in ["room_id", "event_id", "client_name", "sender"] {
            if let value = userInfo[key] as? String { payload[key] = value }
        }
        guard payload["room_id"] != nil || payload["event_id"] != nil else {
            return completion(.silent)
        }
        var answered = false
        let answer: (BannerGate) -> Void = { gate in
            guard !answered else { return }
            answered = true
            completion(gate)
        }
        DispatchQueue.main.async {
            ch.invokeMethod("shouldSuppressBanner", arguments: payload) { reply in
                answer((reply as? String).flatMap(BannerGate.init(rawValue:)) ?? .silent)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { answer(.silent) }
    }

    /// Снять УЖЕ ПОКАЗАННЫЕ системой уведомления комнаты. Ищем по
    /// `threadIdentifier` — его на каждом баннере проставляет NSE
    /// (`NotificationService.swift`), поэтому здесь видны и те уведомления,
    /// которых плагин flutter_local_notifications не знает (у них идентификатор
    /// APNs-UUID, а плагин ищет по своему числовому id).
    static func cancelDelivered(roomId: String, completion: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { notification in
                    notification.request.content.threadIdentifier == roomId
                        || notification.request.content.userInfo["room_id"] as? String == roomId
                }
                .map { $0.request.identifier }
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
            completion()
        }
    }

    /// Снять опоздавший APNs-баннер конкретного события ПОСЛЕ того, как его
    /// показала система. Нужен, когда Liza не активна: `willPresent` там не
    /// вызывается, помешать показу нельзя — можно только убрать показанное.
    /// Dart решает на приходе пуша (`application(_:didReceiveRemoteNotification:)`
    /// приходит за ~0,3 с), система показывает оригинал позже (после NSE или его
    /// таймаута ~2 с) — поэтому опрашиваем `getDeliveredNotifications` до
    /// [deadline]. Матч строго по `userInfo["event_id"]`: локальные уведомления
    /// плагина несут `payload`, а не `event_id`, свежий баннер той же комнаты
    /// по `room_id` снимать нельзя. Возвращает миллисекунды до снятия либо nil.
    static func retractDelivered(
        eventId: String,
        deadline: TimeInterval = 10,
        interval: TimeInterval = 0.25,
        completion: @escaping (Int?) -> Void
    ) {
        let center = UNUserNotificationCenter.current()
        let started = Date()
        func attempt() {
            center.getDeliveredNotifications { delivered in
                let ids = delivered
                    .filter { ($0.request.content.userInfo["event_id"] as? String) == eventId }
                    .map { $0.request.identifier }
                if !ids.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: ids)
                    completion(Int(Date().timeIntervalSince(started) * 1000))
                    return
                }
                if Date().timeIntervalSince(started) >= deadline {
                    completion(nil)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: attempt)
            }
        }
        attempt()
    }

    static func deliveredRoomIds(completion: @escaping ([String]) -> Void) {
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            var rooms: [String] = []
            for notification in delivered {
                let content = notification.request.content
                let roomId = (content.userInfo["room_id"] as? String)
                    ?? (content.threadIdentifier.isEmpty ? nil : content.threadIdentifier)
                if let roomId = roomId, !rooms.contains(roomId) { rooms.append(roomId) }
            }
            completion(rooms)
        }
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let ch = FlutterMethodChannel(
            name: "com.prodamus.laba.liza/apns",
            binaryMessenger: registrar.messenger
        )
        let instance = MacApnsPushPlugin()
        registrar.addMethodCallDelegate(instance, channel: ch)

        queue.sync {
            channel = ch
            // If token arrived before Flutter was ready
            if let token = pendingToken {
                DispatchQueue.main.async {
                    ch.invokeMethod("onToken", arguments: token)
                }
            }
        }
        observeScreenLock()
    }

    // MARK: - Блокировка экрана

    /// Заблокирован ли сеанс (lock screen / заставка с паролем). Открытый чат
    /// на залоченном Маке иначе шлёт квитанции «прочитано» (окно видимо, Flutter
    /// даёт лишь `inactive`), а серверная read-grace по такой квитанции глушит
    /// пуш на телефон — сообщение осталось бы без единого сигнала.
    static func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private static var screenLockObserved = false

    /// `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` приходят через
    /// DistributedNotificationCenter в момент смены — Dart держит зеркало.
    private static func observeScreenLock() {
        queue.sync {
            guard !screenLockObserved else { return }
            screenLockObserved = true
        }
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { _ in
            queue.sync { channel }?.invokeMethod("onScreenLock", arguments: true)
        }
        center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { _ in
            queue.sync { channel }?.invokeMethod("onScreenLock", arguments: false)
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestPermission":
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            ) { granted, _ in
                DispatchQueue.main.async {
                    if granted {
                        NSApplication.shared.registerForRemoteNotifications()
                    }
                    result(granted)
                }
            }
        case "getToken":
            MacApnsPushPlugin.queue.sync {
                if let token = MacApnsPushPlugin.pendingToken {
                    result(token)
                } else {
                    NSApplication.shared.registerForRemoteNotifications()
                    MacApnsPushPlugin.pendingTokenResult = result
                    // Timeout after 15 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                        MacApnsPushPlugin.queue.sync {
                            if let pending = MacApnsPushPlugin.pendingTokenResult {
                                pending(FlutterError(
                                    code: "TIMEOUT",
                                    message: "APNs token not received within timeout",
                                    details: nil
                                ))
                                MacApnsPushPlugin.pendingTokenResult = nil
                            }
                        }
                    }
                }
            }
        case "getInitialNotificationTap":
            // Клик по баннеру при незапущенной Лизе: система запускает
            // приложение и отдаёт `didReceive` до того, как Dart поставил
            // слушателей — тап ждёт здесь, как на iOS.
            MacApnsPushPlugin.queue.sync {
                let tap = MacApnsPushPlugin.pendingNotificationTap
                MacApnsPushPlugin.pendingNotificationTap = nil
                result(tap)
            }
        case "saveCredentials":
            // macOS теперь имеет NSE (общий файл с iOS) — он читает эти ключи из
            // App Group для загрузки аватара, поэтому реально пишем (раньше был
            // no-op с устаревшим комментарием «No NSE on macOS»).
            let credArgs = call.arguments as? [String: String]
            let credDefaults = UserDefaults(suiteName: lizaAppGroup())
            credDefaults?.set(credArgs?["homeserverUrl"], forKey: "homeserverUrl")
            credDefaults?.set(credArgs?["accessToken"], forKey: "accessToken")
            result(true)
        case "setActiveRoom":
            // Открытый на экране чат (Dart шлёт null при уходе с чата или в фон).
            // Живёт только в памяти процесса: в App Group значение пережило бы
            // kill и глушило бы уведомления уже закрытого чата.
            let args = call.arguments as? [String: Any]
            MacApnsPushPlugin.activeRoomId = args?["roomId"] as? String
            MacApnsPushPlugin.activeClientName = args?["clientName"] as? String
            MacApnsPushPlugin.activeSingleClient = args?["singleClient"] as? Bool ?? true
            result(true)
        case "saveBadgeCount":
            // Клиент-авторитетное число видимых непрочитанных → App Group, откуда
            // его читают NSE (закрытое приложение) и AppDelegate.willPresent
            // (foreground-banner) вместо сырого серверного counts.unread.
            let badgeArgs = call.arguments as? [String: Any]
            let count = badgeArgs?["count"] as? Int ?? 0
            let badgeDefaults = UserDefaults(suiteName: lizaAppGroup())
            badgeDefaults?.set(count, forKey: "badge_count")
            result(true)
        case "refreshDockBadge":
            // K-A: при активном (frontmost) окне macOS Dock не всегда
            // перерисовывает бейдж сразу после присвоения dockTile.badgeLabel
            // (его ставит flutter_new_badger). Форсим перерисовку иконки —
            // иначе клиент насчитал N, badgeLabel="N", а в доке визуально пусто
            // до переключения приложения. Диагностика 2026-08-31.
            DispatchQueue.main.async {
                NSApplication.shared.dockTile.display()
                result(true)
            }
        case "clearingDone":
            // Парная к iOS: там ответ отпускает фоновое окно clearing-пуша. macOS
            // не будит приложение ради тихого пуша — держать нечего.
            result(true)
        case "cancelDeliveredForRoom":
            let args = call.arguments as? [String: Any]
            guard let roomId = args?["roomId"] as? String, !roomId.isEmpty else {
                return result(false)
            }
            MacApnsPushPlugin.cancelDelivered(roomId: roomId) { result(true) }
        case "deliveredRoomIds":
            MacApnsPushPlugin.deliveredRoomIds { rooms in
                DispatchQueue.main.async { result(rooms) }
            }
        case "retractDelivered":
            let args = call.arguments as? [String: Any]
            guard let eventId = args?["eventId"] as? String, !eventId.isEmpty else {
                return result(nil)
            }
            MacApnsPushPlugin.retractDelivered(eventId: eventId) { ms in
                DispatchQueue.main.async { result(ms) }
            }
        case "getScreenLocked":
            result(MacApnsPushPlugin.isScreenLocked())
        case "getNotificationSettings":
            // Единственный способ отличить «ОС подавила рендер» от «мы не
            // записали». Read-back бейджа на macOS ТАВТОЛОГИЧЕН: в
            // flutter_new_badger `setBadge` пишет dockTile.badgeLabel и всегда
            // возвращает успех (PERMISSION_DENIED там невозможен), а `getBadge`
            // читает ТУ ЖЕ in-process переменную — совпадение гарантировано
            // архитектурно, даже когда система бейдж не рисует. Поэтому
            // спрашиваем САМУ ОС (диагностика 2026-09-09).
            UNUserNotificationCenter.current().getNotificationSettings { s in
                DispatchQueue.main.async {
                    result([
                        "authorization": s.authorizationStatus.rawValue,
                        "alert": s.alertSetting.rawValue,
                        "badge": s.badgeSetting.rawValue,
                        "sound": s.soundSetting.rawValue,
                    ])
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Called from AppDelegate

    public static func didRegisterForRemoteNotifications(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()

        queue.sync {
            pendingToken = token
            DispatchQueue.main.async {
                channel?.invokeMethod("onToken", arguments: token)
            }
            if let pending = pendingTokenResult {
                pending(token)
                pendingTokenResult = nil
            }
        }
    }

    public static func didFailToRegisterForRemoteNotifications(error: Error) {
        queue.sync {
            if let pending = pendingTokenResult {
                pending(FlutterError(
                    code: "REGISTRATION_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
                pendingTokenResult = nil
            }
        }
    }

    public static func didReceiveRemoteNotification(userInfo: [String: Any]) {
        DispatchQueue.main.async {
            queue.sync {
                channel?.invokeMethod("onMessage", arguments: userInfo)
            }
        }
    }

    /// Тап по уведомлению (зеркало iOS `ApnsPushPlugin.didReceiveNotificationTap`).
    /// Работает и для баннеров, нарисованных нативно из APNs, и для локальных:
    /// делегатом центра уведомлений остаётся AppDelegate, поэтому обработчик
    /// плагина flutter_local_notifications на macOS не вызывается вовсе.
    public static func didReceiveNotificationTap(userInfo: [AnyHashable: Any]) {
        var payload: [String: String] = [
            "room_id": userInfo["room_id"] as? String ?? "",
            "event_id": userInfo["event_id"] as? String ?? "",
            "client_name": userInfo["client_name"] as? String ?? "",
        ]
        // Локальное уведомление (Dart через flutter_local_notifications) несёт
        // не top-level ключи APNs, а строку `LizaPushPayload` вида
        // `clientName|roomId|eventId` в userInfo["payload"].
        if payload["room_id"]!.isEmpty,
           let raw = userInfo["payload"] as? String {
            let parts = raw.components(separatedBy: "|")
            if parts.count == 3 {
                payload["client_name"] = parts[0] == "null" ? "" : parts[0]
                payload["room_id"] = parts[1]
                payload["event_id"] = parts[2] == "null" ? "" : parts[2]
            }
        }
        guard !payload["room_id"]!.isEmpty else { return }
        DispatchQueue.main.async {
            queue.sync {
                if let ch = channel {
                    ch.invokeMethod("onNotificationTap", arguments: payload)
                } else {
                    // Flutter ещё не зарегистрировал плагин — отдадим через
                    // getInitialNotificationTap.
                    pendingNotificationTap = payload
                }
            }
        }
    }
}
