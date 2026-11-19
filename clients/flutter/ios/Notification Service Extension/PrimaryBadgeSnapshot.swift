import Foundation

/// Один снимок числа и владельца для Runner и NSE. Только известное множество
/// клиентов позволяет отнести фоновый alert к главному аккаунту.
enum PrimaryBadgeSnapshot {
    private static let key = "primary_badge_snapshot"

    static func setClients(_ names: [String], defaults: UserDefaults?) {
        let previous = defaults?.stringArray(forKey: "client_names")
        if previous?.first != names.first {
            defaults?.removeObject(forKey: key)
        }
        defaults?.set(names, forKey: "client_names")
    }

    static func save(_ args: [String: Any]?, defaults: UserDefaults?) -> Bool {
        guard let defaults = defaults, let owner = args?["clientName"] as? String, !owner.isEmpty,
              let count = args?["count"] as? Int, count >= 0,
              defaults.stringArray(forKey: "client_names")?.first == owner else { return false }
        defaults.set(["clientName": owner, "count": count], forKey: key)
        return true
    }

    static func forAlert(owner: String?, defaults: UserDefaults?) -> NSNumber? {
        guard let names = defaults?.stringArray(forKey: "client_names"),
              let primary = names.first, !primary.isEmpty else { return nil }
        let recipient = owner?.isEmpty == false ? owner : (names.count == 1 ? primary : nil)
        guard let recipient = recipient, names.contains(recipient) else { return nil }

        let snapshot = defaults?.dictionary(forKey: key)
        let count = snapshot?["clientName"] as? String == primary ? snapshot?["count"] as? Int : nil
        // Сохраняем нижнюю границу одного alert только у доказанного primary.
        // Входящее событие вторичного аккаунта не меняет ноль первичного.
        if recipient == primary { return NSNumber(value: max(1, count ?? 0)) }
        return count.map { NSNumber(value: $0) }
    }
}
