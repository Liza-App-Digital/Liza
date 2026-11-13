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

        // AC:RL-push-clearing-alert-v2/6 — пуш снятия v2 (liza_clear=2, без
        // room_id/event_id): один callback с ПУСТЫМ содержимым (с filtering
        // entitlement iOS его подавит), стадия nseSuppressed, а не nseError.
        let clearDir = base.appendingPathComponent("clear")
        let journal = NativePushJournal(directory: clearDir)
        let service = NotificationService()
        service.diagnosticJournal = journal
        var sweptFor: String?
        service.readBannerSweep = { clientName, _, completion in
            sweptFor = clientName
            DispatchQueue.global().async { completion(2) }
        }
        let content = UNMutableNotificationContent()
        content.body = "Новые сообщения прочитаны"
        content.userInfo = ["liza_clear": 2, "client_name": "nse-test"]
        let request = UNNotificationRequest(identifier: "clear", content: content, trigger: nil)
        let done = DispatchSemaphore(value: 0)
        var calls = 0
        service.didReceive(request) { result in
            calls += 1
            assert(result.title.isEmpty && result.body.isEmpty, "clear push must deliver empty content")
            done.signal()
        }
        assert(done.wait(timeout: .now() + 6) == .success, "clear push: no callback")
        Thread.sleep(forTimeInterval: 0.2)
        assert(calls == 1, "clear push: callbacks=\(calls)")
        let stages = (journal.read() ?? []).compactMap { $0["s"] as? String }
        assert(stages.contains("nseSuppressed"), "stages=\(stages)")
        assert(!stages.contains("nseError"), "stages=\(stages)")
        assert(sweptFor == "nse-test", "sweep must use client_name token, got \(String(describing: sweptFor))")
        // Истечение времени после ответа не должно показать запасной текст.
        service.serviceExtensionTimeWillExpire()
        assert(calls == 1, "expire after clear: callbacks=\(calls)")
        print("NotificationService: alert-clearing v2 suppressed PASS")
    }
}
