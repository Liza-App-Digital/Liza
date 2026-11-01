import Foundation
import UserNotifications

// ledger:RL-push-native-diagnostics
@main
struct NSEHandlerTest {
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nse-handler-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let unavailable = base.appendingPathComponent("not-a-directory")
        try Data().write(to: unavailable)
        // AC:RL-push-native-diagnostics/5 — реальный NSE path с недоступным
        // spool сохраняет единственный callback и исходный результат ветки.
        for directory in [base.appendingPathComponent("journal"), unavailable] {
            let service = NotificationService()
            service.diagnosticJournal = NativePushJournal(directory: directory)
            let content = UNMutableNotificationContent()
            content.title = "sentinel"
            let request = UNNotificationRequest(identifier: "test", content: content, trigger: nil)
            var calls = 0
            service.didReceive(request) { result in
                calls += 1
                // Существующая ветка missing event/room возвращает empty content.
                assert(result.title.isEmpty && result.body.isEmpty)
            }
            assert(calls == 1)
        }
        print("NotificationService: callback with healthy/failed diagnostic storage PASS")
    }
}
