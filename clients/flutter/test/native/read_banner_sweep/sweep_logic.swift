import Foundation

// ledger:RL-push-read-banner-sweep
// Чистая логика ReadBannerSweep: разбор /notifications, выбор токена по
// client_name, фильтр владельца баннера. Сеть и UNUserNotificationCenter не нужны.
@main
struct ReadBannerSweepTest {
    static func main() {
        var fails = 0
        func check(_ c: Bool, _ m: String) { if !c { fails += 1; print("FAIL", m) } else { print("ok", m) } }
        let json = """
        {"notifications":[{"read":true,"event":{"event_id":"$a"}},{"read":false,"event":{"event_id":"$b"}},{"read":true,"event":{}}]}
        """.data(using: .utf8)!
        check(ReadBannerSweep.readEventIds(from: json) == ["$a"], "read ids")
        check(ReadBannerSweep.readEventIds(from: Data("x".utf8)) == nil, "bad json nil")
        let d = UserDefaults(suiteName: "rbs.test.\(UUID())")!
        check(ReadBannerSweep.credentials(clientName: "A", defaults: d) == nil, "no creds")
        d.set("hs", forKey: "homeserverUrl"); d.set("legacy", forKey: "accessToken")
        check(ReadBannerSweep.credentials(clientName: "A", defaults: d)?.accessToken == "legacy", "legacy single")
        d.set(["A","B"], forKey: "client_names")
        check(ReadBannerSweep.credentials(clientName: "A", defaults: d) == nil, "legacy refused multi")
        check(ReadBannerSweep.credentials(clientName: nil, defaults: d) == nil, "no cn multi")
        d.set("hsA", forKey: "homeserverUrl.A"); d.set("tA", forKey: "accessToken.A")
        check(ReadBannerSweep.credentials(clientName: "A", defaults: d) == .init(homeserver: "hsA", accessToken: "tA"), "per client")
        check(ReadBannerSweep.credentials(clientName: "B", defaults: d) == nil, "B absent")
        let del: [ReadBannerSweep.Delivered] = [
         .init(identifier: "1", userInfo: ["event_id": "$a", "client_name": "A"]),
         .init(identifier: "2", userInfo: ["event_id": "$a", "client_name": "B"]),
         .init(identifier: "3", userInfo: ["event_id": "$b", "client_name": "A"]),
         .init(identifier: "4", userInfo: ["event_id": "$a"]),
        ]
        check(ReadBannerSweep.identifiersToRemove(delivered: del, readEventIds: ["$a"], clientName: "A", clientCount: 2) == ["1"], "multi owner")
        check(ReadBannerSweep.identifiersToRemove(delivered: del, readEventIds: ["$a"], clientName: "A", clientCount: 1) == ["1","4"], "single legacy")
        check(ReadBannerSweep.notificationsRequest(.init(homeserver: "https://h/", accessToken: "t"))?.url?.absoluteString == "https://h/_matrix/client/v3/notifications?limit=50", "url")
        // AC-17: выход из аккаунта убирает его токен; легаси — если тот же токен.
        let f = UserDefaults(suiteName: "rbs.forget.\(UUID())")!
        f.set(["A","B"], forKey: "client_names")
        f.set("hsA", forKey: "homeserverUrl.A"); f.set("tA", forKey: "accessToken.A")
        f.set("hsB", forKey: "homeserverUrl.B"); f.set("tB", forKey: "accessToken.B")
        f.set("hsA", forKey: "homeserverUrl"); f.set("tA", forKey: "accessToken")
        ReadBannerSweep.forgetCredentials(clientName: "A", remaining: ["B"], defaults: f)
        check(f.string(forKey: "accessToken.A") == nil, "forget own token")
        check(f.string(forKey: "accessToken") == nil, "forget legacy with same token")
        check(f.string(forKey: "accessToken.B") == "tB", "keep other account")
        check(f.stringArray(forKey: "client_names") == ["B"], "client_names updated")
        f.set("hsB", forKey: "homeserverUrl"); f.set("tB", forKey: "accessToken")
        f.set("tC", forKey: "accessToken.C")
        ReadBannerSweep.forgetCredentials(clientName: "C", remaining: ["B"], defaults: f)
        check(f.string(forKey: "accessToken") == "tB", "keep legacy of other account")
        ReadBannerSweep.forgetCredentials(clientName: "B", remaining: [], defaults: f)
        check(f.string(forKey: "accessToken") == nil && f.string(forKey: "homeserverUrl") == nil, "last account clears legacy")
        if fails > 0 { exit(1) }
        print("ReadBannerSweep PASS")
    }
}
