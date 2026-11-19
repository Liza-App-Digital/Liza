import Foundation
import UserNotifications

/// HTTP-граница штатного ReadBannerSweep.run. Сеть/Matrix и настройки ОС не меняются.
private final class ReadEventsProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"notifications":[{"read":true,"event":{"event_id":"$a"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

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
        check(ReadBannerSweep.credentials(clientName: "A", defaults: d) == nil, "legacy unknown inventory")
        d.set(["A"], forKey: "client_names")
        check(ReadBannerSweep.credentials(clientName: "B", defaults: d) == nil, "legacy other account")
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
         .init(identifier: "5", userInfo: ["payload": "B|!shared|$a"]),
         .init(identifier: "6", userInfo: ["payload": "A|!shared|$a"]),
        ]
        check(ReadBannerSweep.identifiersToRemove(delivered: del, readEventIds: ["$a"], clientName: "A", clientCount: 2) == ["1","6"], "multi owner")
        check(ReadBannerSweep.identifiersToRemove(delivered: del, readEventIds: ["$a"], clientName: "A", clientCount: 1) == ["1","4","6"], "single legacy")
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
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReadEventsProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        d.set("https://fixture.invalid", forKey: "homeserverUrl.A")
        let content = UNMutableNotificationContent()
        content.userInfo = ["room_id": "!shared", "event_id": "$a", "client_name": "A"]
        let note = UNNotificationRequest(identifier: "read-note", content: content, trigger: nil)
        for stays in [true, false] {
            let finished = DispatchSemaphore(value: 0)
            var removalIssued = false
            var readBack = false
            var observed = -1
            ReadBannerSweep.run(clientName: "A", defaults: d, listRequests: { reply in
                if removalIssued { readBack = true }
                reply(removalIssued && !stays ? [] : [note])
            }, removeRequests: { ids in
                removalIssued = ids == ["read-note"]
            }, session: session) { count in
                observed = count
                finished.signal()
            }
            check(finished.wait(timeout: .now() + 2) == .success, "NSE sweep completion")
            check(removalIssued && readBack && observed == (stays ? 0 : 1), "NSE readback stays=\(stays) observed=\(observed)")
        }
        if fails > 0 { exit(1) }
        print("ReadBannerSweep PASS")
    }
}
