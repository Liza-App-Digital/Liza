import Foundation

// ledger:RL-push-clearing-alert-v2
// AC:RL-push-clearing-alert-v2/7 — решение AppDelegate.willPresent на переднем плане.
@main
struct PushPresentationTest {
    static func main() {
        var fails = 0
        func check(_ c: Bool, _ m: String) { if !c { fails += 1; print("FAIL", m) } else { print("ok", m) } }
        func d(_ u: [AnyHashable: Any], remote: Bool = true, active: Bool = true, room: Bool = false) -> PushPresentation {
            PushPresentation.decide(userInfo: u, isRemote: remote, appActive: active, inActiveRoom: room)
        }
        check(d(["liza_clear": NSNumber(value: 2)]) == .suppress, "clear v2 suppressed")
        check(d(["liza_clear": NSNumber(value: 2), "room_id": "!a"], active: false) == .suppress, "clear v2 suppressed even with room")
        check(d(["liza_clear": NSNumber(value: 1)]) == .plugin, "clear v1 is not v2")
        check(d(["liza_clear": NSNumber(value: 2)], remote: false) == .plugin, "local notification goes to plugin")
        check(d(["room_id": "!a"]) == .show, "message push shown")
        check(d(["room_id": "!a"], room: true) == .suppress, "active room suppressed")
        check(d(["room_id": "!a"], active: false, room: true) == .show, "background shows")
        check(d([:]) == .plugin, "no room → plugin")
        if fails > 0 { exit(1) }
        print("PushPresentation PASS")
    }
}
