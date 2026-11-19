import Foundation
import UserNotifications

// ledger:RL-push-causal-contract
@main
struct DeliveredSelectionTest {
    static func main() {
        func request(_ id: String, _ owner: String?, _ event: String, local: Bool = false) -> UNNotificationRequest {
            let c = UNMutableNotificationContent()
            c.threadIdentifier = "!shared"
            if local {
                c.userInfo = ["payload": "\(owner ?? "null")|!shared|\(event)"]
            } else {
                c.userInfo = ["room_id": "!shared", "event_id": event]
                c.userInfo["client_name"] = owner
            }
            return UNNotificationRequest(identifier: id, content: c, trigger: nil)
        }

        let a = request("a", "A", "$e2")
        let b = request("b", "B", "$e2")
        let legacy = request("legacy", nil, "$e2")
        let local = request("11", "A", "$e2", local: true)
        let localB = request("12", "B", "$e2", local: true)
        let list = [a, b, legacy, local, localB]
        var failed = false
        func check(_ actual: [String], _ expected: [String], _ name: String) {
            if actual != expected {
                print("FAIL \(name): expected \(expected), got \(actual)")
                failed = true
            }
        }
        func selected(_ now: [UNNotificationRequest], _ snapshot: [UNNotificationRequest],
                      single: Bool = false) -> [String] {
            let reads = snapshot.compactMap { request -> [String: String]? in
                guard var descriptor = DeliveredBanner.descriptor(request) else { return nil }
                descriptor["readBy"] = "A"
                return descriptor
            }
            return DeliveredBanner.matching(now, reads: reads, singleAccount: single).map { $0.identifier }
        }
        check(selected(list, list), ["a", "11"], "общая комната, то же событие, FLN и чужой аккаунт")
        check(selected(list, list, single: true), ["a", "legacy", "11"], "один известный владелец")
        let e3 = request("11", "A", "$e3", local: true)
        check(selected([b, e3, localB], [local]), [], "тот же request ID занят новым событием")
        check(selected([request("a", "B", "$e2")], [a]), [], "владелец сменился после снимка")
        check(selected([request("?", "A", "")], [request("?", "A", "")]), [], "событие неизвестно")
        // Вызываем production-операцию целиком. Ответ об отсутствии требует
        // совпадения до удаления и второй выборки без того же ID.
        var read = DeliveredBanner.descriptor(a)!
        read["readBy"] = "A"
        func verifyReadback(_ snapshots: [[UNNotificationRequest]], ids: [String], absent: [String]) {
            var remaining = snapshots
            var removed = [String]()
            var result: [String]?
            DeliveredBanner.remove([read], singleAccount: false,
                listRequests: { reply in reply(remaining.removeFirst()) },
                removeRequests: { removed.append(contentsOf: $0) },
                done: { result = $0 })
            check(removed, ids, "точный вызов remove")
            check(result ?? ["невызванный completion"], absent, "подтверждённое отсутствие")
            if !remaining.isEmpty { failed = true }
        }
        verifyReadback([[a, b], [b]], ids: ["a"], absent: ["a"])
        verifyReadback([[a, b], [a, b]], ids: ["a"], absent: [])
        verifyReadback([[b]], ids: [], absent: [])
        verifyReadback([[a], [request("a", "A", "$e3")]], ids: ["a"], absent: [])
        if failed { exit(1) }
        print("DeliveredBanner PASS")
    }
}
