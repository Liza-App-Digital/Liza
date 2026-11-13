import Foundation
import UserNotifications

/// Р2 L1/L2 (спека 2026-11-12-push-sync-industry-alignment): снимает баннеры
/// событий, уже прочитанных на другом устройстве, БЕЗ фонового clearing-пуша.
/// Источник правды — сервер: `GET /notifications` отдаёт `read=true` для
/// событий до read-receipt пользователя. Ошибка/таймаут/нет токена → не
/// снимаем НИЧЕГО (fail-open: лишний баннер лучше потерянного).
///
/// Файл живёт в папке NSE (входит в расширение через synchronized group) и
/// явно добавлен в таргет Runner — им же пользуется BGAppRefresh приложения.
enum ReadBannerSweep {
    static let timeout: TimeInterval = 3
    static let limit = 50

    struct Credentials: Equatable {
        let homeserver: String
        let accessToken: String
    }

    /// Токен аккаунта-адресата. Ключи `accessToken.<client_name>` пишет
    /// background_push.dart на каждый аккаунт. Легаси-ключ без суффикса берём
    /// только при одном аккаунте: иначе сняли бы баннеры по чужим прочтениям.
    static func credentials(clientName: String?, defaults: UserDefaults?) -> Credentials? {
        guard let defaults = defaults else { return nil }
        let names = defaults.stringArray(forKey: "client_names") ?? []
        if let cn = clientName, !cn.isEmpty {
            if let hs = defaults.string(forKey: "homeserverUrl.\(cn)"),
               let token = defaults.string(forKey: "accessToken.\(cn)"),
               !hs.isEmpty, !token.isEmpty {
                return Credentials(homeserver: hs, accessToken: token)
            }
            guard names.count <= 1 else { return nil }
        } else if names.count > 1 {
            return nil
        }
        guard let hs = defaults.string(forKey: "homeserverUrl"),
              let token = defaults.string(forKey: "accessToken"),
              !hs.isEmpty, !token.isEmpty else { return nil }
        return Credentials(homeserver: hs, accessToken: token)
    }

    /// Выход из аккаунта [clientName]: его токен больше не должен лежать в App
    /// Group (NSE ходил бы с ним в сервер до 401). Легаси-ключи снимаем, если в
    /// них тот же токен или аккаунтов не осталось — следующий `setupPush`
    /// текущего аккаунта запишет их заново. `client_names` = оставшиеся.
    static func forgetCredentials(clientName: String, remaining: [String], defaults: UserDefaults?) {
        guard let defaults = defaults, !clientName.isEmpty else { return }
        let token = defaults.string(forKey: "accessToken.\(clientName)")
        defaults.removeObject(forKey: "homeserverUrl.\(clientName)")
        defaults.removeObject(forKey: "accessToken.\(clientName)")
        let legacy = defaults.string(forKey: "accessToken")
        if remaining.isEmpty || (token != nil && legacy == token) {
            defaults.removeObject(forKey: "homeserverUrl")
            defaults.removeObject(forKey: "accessToken")
        }
        defaults.set(remaining.filter { $0 != clientName }, forKey: "client_names")
    }

    /// event_id с `read=true` из ответа `/notifications`. Битый JSON → nil
    /// (вызывающий ничего не снимает), а не пустое множество.
    static func readEventIds(from data: Data) -> Set<String>? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["notifications"] as? [[String: Any]] else { return nil }
        var ids = Set<String>()
        for item in items where (item["read"] as? Bool) == true {
            if let event = item["event"] as? [String: Any],
               let id = event["event_id"] as? String, !id.isEmpty {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Минимум, нужный для решения: id запроса + его userInfo.
    struct Delivered {
        let identifier: String
        let userInfo: [AnyHashable: Any]
    }

    /// Какие доставленные баннеры снять: событие прочитано И баннер принадлежит
    /// этому аккаунту. Баннер без client_name (старый pusher) — свой только
    /// при одном аккаунте (тот же фильтр, что clearDeliveredIfAllRead).
    static func identifiersToRemove(
        delivered: [Delivered],
        readEventIds: Set<String>,
        clientName: String?,
        clientCount: Int
    ) -> [String] {
        let me = clientName ?? ""
        return delivered.compactMap { d in
            guard let eventId = d.userInfo["event_id"] as? String,
                  readEventIds.contains(eventId) else { return nil }
            let owner = d.userInfo["client_name"] as? String ?? ""
            if owner.isEmpty || me.isEmpty {
                return clientCount <= 1 ? d.identifier : nil
            }
            return owner == me ? d.identifier : nil
        }
    }

    static func notificationsRequest(_ creds: Credentials) -> URLRequest? {
        let base = creds.homeserver.hasSuffix("/") ? String(creds.homeserver.dropLast()) : creds.homeserver
        guard let url = URL(string: "\(base)/_matrix/client/v3/notifications?limit=\(limit)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        return request
    }

    /// Сам проход. completion(число снятых) вызывается РОВНО один раз и не
    /// позже `timeout` + время getDelivered — даже если сеть висит.
    static func run(
        clientName: String?,
        defaults: UserDefaults?,
        center: UNUserNotificationCenter = .current(),
        session: URLSession = .shared,
        completion: @escaping (Int) -> Void
    ) {
        guard let creds = credentials(clientName: clientName, defaults: defaults),
              let request = notificationsRequest(creds) else {
            completion(0)
            return
        }
        let clientCount = defaults?.stringArray(forKey: "client_names")?.count ?? 0
        let once = Once(completion)
        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let data = data,
                  let read = readEventIds(from: data), !read.isEmpty else {
                once.call(0)
                return
            }
            center.getDeliveredNotifications { notes in
                let ids = identifiersToRemove(
                    delivered: notes.map { Delivered(identifier: $0.request.identifier,
                                                     userInfo: $0.request.content.userInfo) },
                    readEventIds: read,
                    clientName: clientName,
                    clientCount: clientCount
                )
                if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
                once.call(ids.count)
            }
        }
        task.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 0.5) {
            task.cancel()
            once.call(0)
        }
    }

    final class Once {
        private let lock = NSLock()
        private var fn: ((Int) -> Void)?
        init(_ fn: @escaping (Int) -> Void) { self.fn = fn }
        func call(_ value: Int) {
            lock.lock()
            let f = fn
            fn = nil
            lock.unlock()
            f?(value)
        }
    }
}
