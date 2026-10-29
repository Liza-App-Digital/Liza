import Flutter
import UIKit
import UserNotifications

/// App Group приложения, вычисленная из bundle id.
///
/// Группа всегда `group.<bundle id основного приложения>`. Для расширений
/// (NSE, Share) bundle id содержит лишний последний компонент — отбрасываем.
/// Вычисляем, а не хардкодим: bundle id меняется при смене Apple-аккаунта,
/// и рассинхрон литерала с entitlements ломает пуши МОЛЧА —
/// UserDefaults(suiteName:) вернёт пустой контейнер без ошибки.
func lizaAppGroup(for bundle: Bundle = .main) -> String {
    guard let bundleId = bundle.bundleIdentifier else { return "" }
    let isExtension = bundle.bundleURL.pathExtension == "appex"
    let appId = isExtension
        ? bundleId.split(separator: ".").dropLast().joined(separator: ".")
        : bundleId
    return "group.\(appId)"
}

/// Native APNs plugin — replaces FcmSharedIsolate.
/// Provides raw APNs device token (hex) and push handling via MethodChannel.
public class ApnsPushPlugin: NSObject, FlutterPlugin {
    private static var channel: FlutterMethodChannel?
    private static var pendingToken: String?
    private static var pendingTokenResult: FlutterResult?
    private static var pendingNotificationTap: [String: String]?
    static var activeRoomId: String?
    static var activeClientName: String?
    static var activeSingleClient = true
    /// Завершения фоновых пробуждений по clearing-пушу, ждущие ответа Dart, —
    /// по id пуша: ответ на пуш A не должен отпускать окно пуша B, чья
    /// обработка ещё идёт (несколько чатов прочитаны подряд). Доступ ТОЛЬКО с
    /// главной очереди (method channel, asyncAfter main) — синхронизации нет.
    private static var pendingClearingCompletions: [String: () -> Void] = [:]

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

    public static func register(with registrar: FlutterPluginRegistrar) {
        let ch = FlutterMethodChannel(
            name: "com.prodamus.laba.liza/apns",
            binaryMessenger: registrar.messenger()
        )
        let instance = ApnsPushPlugin()
        registrar.addMethodCallDelegate(instance, channel: ch)
        channel = ch

        // If token arrived before Flutter was ready
        if let token = pendingToken {
            ch.invokeMethod("onToken", arguments: token)
        }

        // If notification tap arrived before Flutter was ready (cold start)
        if let tap = pendingNotificationTap {
            ch.invokeMethod("onNotificationTap", arguments: tap)
            pendingNotificationTap = nil
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestPermission":
            // Парная реализация к macOS: статус до/после, ошибка и активность
            // приложения — чтобы разбирать `denied` без журналов с устройства.
            let center = UNUserNotificationCenter.current()
            let active = UIApplication.shared.applicationState == .active
            center.getNotificationSettings { before in
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    // Регистрация — как раньше, сразу по ответу; повторное
                    // чтение статуса её не задерживает.
                    if granted {
                        DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
                    }
                    center.getNotificationSettings { after in
                        DispatchQueue.main.async {
                            var out: [String: Any] = [
                                "granted": granted,
                                "before": before.authorizationStatus.rawValue,
                                "after": after.authorizationStatus.rawValue,
                                "active": active,
                            ]
                            if let ns = error as NSError? {
                                out["errorDomain"] = ns.domain
                                out["errorCode"] = ns.code
                            }
                            result(out)
                        }
                    }
                }
            }
        case "getToken":
            if let token = ApnsPushPlugin.pendingToken {
                result(token)
            } else {
                UIApplication.shared.registerForRemoteNotifications()
                ApnsPushPlugin.pendingTokenResult = result
                // Timeout after 15 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    if let pending = ApnsPushPlugin.pendingTokenResult {
                        pending(FlutterError(
                            code: "TIMEOUT",
                            message: "APNs token not received within timeout",
                            details: nil
                        ))
                        ApnsPushPlugin.pendingTokenResult = nil
                    }
                }
            }
        case "getInitialNotificationTap":
            if let tap = ApnsPushPlugin.pendingNotificationTap {
                ApnsPushPlugin.pendingNotificationTap = nil
                result(tap)
            } else {
                result(nil)
            }
        case "saveCredentials":
            let args = call.arguments as? [String: String]
            let defaults = UserDefaults(suiteName: lizaAppGroup())
            defaults?.set(args?["homeserverUrl"], forKey: "homeserverUrl")
            defaults?.set(args?["accessToken"], forKey: "accessToken")
            result(true)
        case "setActiveRoom":
            // Открытый на экране чат (Dart шлёт null при уходе с чата или в фон).
            // Живёт только в памяти процесса: в App Group значение пережило бы
            // kill и глушило бы уведомления уже закрытого чата.
            let args = call.arguments as? [String: Any]
            ApnsPushPlugin.activeRoomId = args?["roomId"] as? String
            ApnsPushPlugin.activeClientName = args?["clientName"] as? String
            ApnsPushPlugin.activeSingleClient = args?["singleClient"] as? Bool ?? true
            result(true)
        case "saveClientNames":
            // Аккаунты устройства — для холодного пути clearing-пуша без Dart
            // (`clearDeliveredIfAllRead`): баннер без client_name натив считает
            // своим, только если аккаунт ровно один.
            let args = call.arguments as? [String: Any]
            let names = args?["names"] as? [String] ?? []
            UserDefaults(suiteName: lizaAppGroup())?.set(names, forKey: "client_names")
            result(true)
        case "clearingDone":
            let args = call.arguments as? [String: Any]
            if let id = args?["id"] as? String,
               let finish = ApnsPushPlugin.pendingClearingCompletions.removeValue(forKey: id) {
                finish()
            }
            result(true)
        case "saveBadgeCount":
            // Клиент-авторитетное число видимых непрочитанных → App Group, откуда
            // его читает NSE при закрытом приложении (вместо сырого counts.unread).
            let args = call.arguments as? [String: Any]
            let count = args?["count"] as? Int ?? 0
            let defaults = UserDefaults(suiteName: lizaAppGroup())
            defaults?.set(count, forKey: "badge_count")
            result(true)
        case "cancelDeliveredForRoom":
            // Баннер, нарисованный NSE, плагину flutter_local_notifications не
            // принадлежит: его идентификатор — UUID от APNs, а плагин ищет по
            // своему числовому id и такие уведомления просто пропускает
            // (`userInfo[NOTIFICATION_ID] == nil`). Снимаем по threadIdentifier —
            // его NSE проставляет равным room_id на каждом баннере.
            let cancelArgs = call.arguments as? [String: Any]
            guard let roomId = cancelArgs?["roomId"] as? String, !roomId.isEmpty else {
                return result(false)
            }
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { delivered in
                let ids = delivered
                    .filter { n in
                        n.request.content.threadIdentifier == roomId
                            || n.request.content.userInfo["room_id"] as? String == roomId
                    }
                    .map { $0.request.identifier }
                if !ids.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: ids)
                }
                DispatchQueue.main.async { result(true) }
            }
        case "deliveredRoomIds":
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                var rooms: [String] = []
                for n in delivered {
                    let content = n.request.content
                    let room = (content.userInfo["room_id"] as? String)
                        ?? (content.threadIdentifier.isEmpty ? nil : content.threadIdentifier)
                    if let room = room, !rooms.contains(room) { rooms.append(room) }
                }
                DispatchQueue.main.async { result(rooms) }
            }
        case "getNotificationSettings":
            // Парная реализация к macOS: клиент обязан уметь отличить «ОС
            // подавила бейдж/баннер» от «мы не записали». На iOS `trySet` до
            // permission-латча выходит МОЛЧА (`_permissionFlowDone`), а
            // `_denied` при этом остаётся false — по логу это неотличимо от
            // успешной записи. Спрашиваем саму систему.
            UNUserNotificationCenter.current().getNotificationSettings { s in
                DispatchQueue.main.async {
                    result([
                        "authorization": s.authorizationStatus.rawValue,
                        "alert": s.alertSetting.rawValue,
                        "badge": s.badgeSetting.rawValue,
                        "sound": s.soundSetting.rawValue,
                        "alertStyle": s.alertStyle.rawValue,
                        "notificationCenter": s.notificationCenterSetting.rawValue,
                        "lockScreen": s.lockScreenSetting.rawValue,
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
        pendingToken = token
        channel?.invokeMethod("onToken", arguments: token)

        if let pending = pendingTokenResult {
            pending(token)
            pendingTokenResult = nil
        }
    }

    public static func didFailToRegisterForRemoteNotifications(error: Error) {
        if let pending = pendingTokenResult {
            pending(FlutterError(
                code: "REGISTRATION_FAILED",
                message: error.localizedDescription,
                details: nil
            ))
            pendingTokenResult = nil
        }
    }

    public static func didReceiveRemoteNotification(userInfo: [AnyHashable: Any]) {
        channel?.invokeMethod("onMessage", arguments: userInfo)
    }

    // MARK: - Clearing-пуш «почисти шторку» (howItWoks/pushes.md §21)

    static let clearingTimeout: TimeInterval = 25
    static let clearingIdKey = "liza_clear_id"

    static func isClearingPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["liza_clear"] as? NSNumber)?.intValue == 1
    }

    /// Тихий пуш: прочитано на другом устройстве. Сначала — то, что натив может
    /// сам (приложение могло быть выгружено: под UIScene Flutter без окна не
    /// поднимается, Dart недоступен), затем — Dart, если он жив: он знает
    /// прочитанность по комнатам. `completionHandler` зовётся РОВНО один раз:
    /// ответ Dart, таймаут или сразу, если Dart нет (повторный вызов — краш,
    /// отсутствие вызова — iOS урезает фоновый бюджет).
    public static func handleClearingPush(
        userInfo: [AnyHashable: Any],
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            completionHandler(.newData)
        }
        clearDeliveredIfAllRead(userInfo) {
            guard let ch = channel else { return finish() }
            let id = UUID().uuidString
            pendingClearingCompletions[id] = finish
            var message = userInfo
            message[clearingIdKey] = id
            ch.invokeMethod("onMessage", arguments: message)
            DispatchQueue.main.asyncAfter(deadline: .now() + clearingTimeout) {
                pendingClearingCompletions.removeValue(forKey: id)
                finish()
            }
        }
    }

    /// Непрочитанных нет (`counts.unread == 0`) — снять все показанные баннеры
    /// этого аккаунта без Dart. Чужой аккаунт (другой client_name) не трогаем;
    /// баннер без client_name — только при одном аккаунте на устройстве.
    /// `unread > 0` натив не разберёт по комнатам — это делает Dart или resume.
    static func clearDeliveredIfAllRead(
        _ userInfo: [AnyHashable: Any],
        then done: @escaping () -> Void
    ) {
        let counts = userInfo["counts"] as? [String: Any]
        guard (counts?["unread"] as? NSNumber)?.intValue == 0 else { return done() }
        let pushClient = userInfo["client_name"] as? String ?? ""
        let names = UserDefaults(suiteName: lizaAppGroup())?
            .stringArray(forKey: "client_names") ?? []
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { n in
                    let owner = n.request.content.userInfo["client_name"] as? String ?? ""
                    if owner.isEmpty { return names.count == 1 }
                    return owner == pushClient
                }
                .map { $0.request.identifier }
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Called from AppDelegate when user taps a remote notification (from NSE).
    /// Extracts room_id and event_id from userInfo and forwards to Flutter.
    /// If Flutter engine isn't ready yet (cold start), stores as pending.
    public static func didReceiveNotificationTap(userInfo: [AnyHashable: Any]) {
        let roomId = userInfo["room_id"] as? String ?? ""
        let eventId = userInfo["event_id"] as? String ?? ""
        // client_name — аккаунт-адресат при мультиаккаунте (Sygnal мержит
        // pusher.data.default_payload в top-level userInfo).
        let clientName = userInfo["client_name"] as? String ?? ""
        let payload: [String: String] = [
            "room_id": roomId,
            "event_id": eventId,
            "client_name": clientName,
        ]
        if let ch = channel {
            ch.invokeMethod("onNotificationTap", arguments: payload)
        } else {
            // Flutter not ready yet — store for delivery after registration
            pendingNotificationTap = payload
        }
    }
}
