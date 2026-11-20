import Foundation
import Darwin

// ledger:RL-push-native-diagnostics
// AC:RL-push-native-diagnostics/14
@main
struct CoordinatedIOTest {
    static let timeout: DispatchTimeInterval = .seconds(5)

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL coordinated IO: \(message)\n", stderr)
            exit(1)
        }
    }

    // Holder не берёт flock: этот тест отличает Foundation gate от старого lock.
    static func waitsForGrant(_ directory: URL, _ name: String, whileHeld: () -> Void = {},
                              _ operation: @escaping () -> Void) {
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: directory, options: [], error: &error) { _ in
            DispatchQueue.global().async {
                started.signal()
                operation()
                finished.signal()
            }
            require(started.wait(timeout: .now() + timeout) == .success, "\(name) started")
            require(finished.wait(timeout: .now() + .milliseconds(200)) == .timedOut,
                    "\(name) bypassed coordinated access")
            whileHeld()
        }
        require(error == nil, "holder grant \(name)")
        require(finished.wait(timeout: .now() + timeout) == .success, "\(name) completes after grant")
    }

    // Clock — существующая точка остановки production retained(), не реплика IO.
    final class PausedClock {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        let pauseAt: Int
        init(_ pauseAt: Int) { self.pauseAt = pauseAt }
        func now() -> Int64 {
            lock.lock()
            calls += 1
            let pause = calls == pauseAt
            lock.unlock()
            if pause {
                entered.signal()
                require(release.wait(timeout: .now() + timeout) == .success, "release retained")
            }
            return Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    static func holdsUntilBodyEnds(_ directory: URL, _ name: String, pauseAt: Int,
                                  operation: @escaping (NativePushJournal) -> Void) {
        let clock = PausedClock(pauseAt)
        let journal = NativePushJournal(directory: directory, clock: clock.now)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { operation(journal); finished.signal() }
        require(clock.entered.wait(timeout: .now() + timeout) == .success, "\(name) reached retained")
        let fd = open(directory.appendingPathComponent("journal.lock").path, O_RDWR)
        require(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0, "\(name) still owns compatibility lock")
        close(fd)
        let attempted = DispatchSemaphore(value: 0)
        let granted = DispatchSemaphore(value: 0)
        let challengerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var error: NSError?
            attempted.signal()
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: directory, options: [], error: &error) { _ in
                granted.signal()
            }
            require(error == nil, "challenger grant \(name)")
            challengerFinished.signal()
        }
        require(attempted.wait(timeout: .now() + timeout) == .success, "challenger started")
        require(granted.wait(timeout: .now() + .milliseconds(200)) == .timedOut,
                "\(name) released coordination before body ended")
        clock.release.signal()
        require(finished.wait(timeout: .now() + timeout) == .success, "\(name) body finished")
        require(granted.wait(timeout: .now() + timeout) == .success, "challenger after \(name)")
        require(challengerFinished.wait(timeout: .now() + timeout) == .success, "challenger finished")
        let released = open(directory.appendingPathComponent("journal.lock").path, O_RDWR)
        require(released >= 0 && flock(released, LOCK_EX | LOCK_NB) == 0, "\(name) unlocked")
        flock(released, LOCK_UN)
        close(released)
    }

    // Реальная межпроцессная Foundation coordination, без внешнего POSIX lock.
    static func modernProcesses(_ directory: URL) throws {
        let child = Process()
        let input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--hold-directory", directory.path]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        require(output.fileHandleForReading.readData(ofLength: 1) == Data([82]), "child coordinator ready")
        let finished = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            require(NativePushJournal(directory: directory).append(.nseReceived), "modern writer success")
            finished.signal()
        }
        require(started.wait(timeout: .now() + timeout) == .success, "modern writer started")
        require(finished.wait(timeout: .now() + .milliseconds(200)) == .timedOut, "modern writer waits for other process")
        input.fileHandleForWriting.write(Data([1]))
        require(finished.wait(timeout: .now() + timeout) == .success, "modern writer after release")
        child.waitUntilExit()
        require(child.terminationStatus == 0, "modern holder exit")
    }

    // AC:RL-push-native-diagnostics/15 — настоящий cancelled Foundation gate.
    static func cancellation(_ base: URL) throws {
        let directory = base.appendingPathComponent("cancelled")
        var deny = true
        let journal = NativePushJournal(directory: directory, makeCoordinator: {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            if deny { coordinator.cancel() }
            return coordinator
        })
        require(!journal.append(.nseReceived), "cancelled append fails")
        require(journal.read() == nil && journal.read() == nil, "cancelled read unknown, failed flush retains backlog")
        require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("journal.lock").path),
                "denied access never opens lock/body")
        deny = false
        waitsForGrant(directory, "loss flush", whileHeld: {
            require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("loss.count").path),
                    "loss flush does not write before grant")
        }) { require(journal.read()?.last?["value"] as? Int == 1, "sync denial recovered once") }
        require(journal.read()?.last?["value"] as? Int == 1, "read failure adds no loss")
        let suite = "cancelled-token-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        deny = true
        require(journal.enqueueToken("POISON_TOKEN_C", preferences: prefs), "cancelled token pending")
        NativePushJournal.writerQueue.sync {}
        require(prefs.string(forKey: "push.diagnostics.token_digest") == nil, "failed token does not advance digest")
        deny = false
        require(journal.read()?.last?["value"] as? Int == 2, "async denial recovered once")
        require(journal.read()?.last?["value"] as? Int == 2, "repeated flush does not double count")
        require(journal.read()?.filter { $0["s"] as? String != "diagnosticLoss" }.isEmpty == true,
                "denial did not create JSON")
        require(journal.enqueueToken("POISON_TOKEN_C", preferences: prefs), "token retry pending")
        let tokens = journal.read()!.filter { $0["s"] as? String == "token" }
        require(tokens.count == 1 && tokens[0]["reason"] as? String == "first", "retry retains first transition")
        require(prefs.string(forKey: "push.diagnostics.token_digest") == NativePushJournal.hash("POISON_TOKEN_C"),
                "successful retry advances digest")
    }

    // Искусственное перенаправление URL; coordination остаётся настоящей.
    final class RedirectingCoordinator: NSFileCoordinator {
        let destination: URL
        init(_ destination: URL) { self.destination = destination; super.init(filePresenter: nil) }
        override func coordinate(writingItemAt url: URL, options: NSFileCoordinator.WritingOptions = [],
                                 error outError: NSErrorPointer, byAccessor writer: (URL) -> Void) {
            super.coordinate(writingItemAt: destination, options: options, error: outError, byAccessor: writer)
        }
    }

    // AC:RL-push-native-diagnostics/16 — все helpers используют granted URL.
    static func scopedURL(_ base: URL) throws {
        let requested = base.appendingPathComponent("requested")
        let granted = base.appendingPathComponent("granted")
        try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        let journal = NativePushJournal(directory: requested, makeCoordinator: { RedirectingCoordinator(granted) })
        require(journal.append(.nseReceived), "redirected append")
        require(journal.read()?.count == 1, "redirected read")
        try Data("bad".utf8).write(to: granted.appendingPathComponent("bad.json"))
        require(journal.read()?.last?["value"] as? Int == 1, "redirected retention and base loss")
        let fd = open(granted.appendingPathComponent("journal.lock").path, O_RDWR)
        require(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "redirected compatibility holder")
        require(!journal.append(.nseReceived), "redirected compatibility conflict")
        flock(fd, LOCK_UN); close(fd)
        require(journal.read()?.last?["value"] as? Int == 2, "redirected contention counter")
        let requestedFiles = try FileManager.default.contentsOfDirectory(atPath: requested.path)
        require(requestedFiles.isEmpty,
                "requested URL has no lock/json/loss IO")
    }

    // AC:RL-push-native-diagnostics/17 — callback capture + общий bounded budget.
    static func queuedTokens(_ base: URL) {
        let directory = base.appendingPathComponent("queued-tokens")
        var now = Int64(Date().timeIntervalSince1970 * 1000)
        let capturedTime = now
        let journal = NativePushJournal(directory: directory, clock: { now })
        let suite = "queued-token-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let blocked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        NativePushJournal.writerQueue.async { blocked.signal(); release.wait() }
        require(blocked.wait(timeout: .now() + timeout) == .success, "writer blocked")
        // Возврат ДО release — иначе watchdog завершит тест.
        require(journal.enqueueToken("POISON_TOKEN_A", preferences: prefs), "first token pending")
        require(journal.enqueueToken("POISON_TOKEN_A", preferences: prefs), "unchanged token pending")
        require(journal.enqueueToken("POISON_TOKEN_B", preferences: prefs), "rotated token pending")
        require(journal.enqueue(.token, reason: .registration_failed), "failure pending")
        for _ in 0..<60 { require(journal.enqueue(.nseReceived), "shared budget accepts event") }
        require(!journal.enqueueToken("POISON_TOKEN_REJECTED", preferences: prefs), "shared token budget bounded")
        require(prefs.string(forKey: "push.diagnostics.token_digest") == nil, "no early digest update")
        require(!FileManager.default.fileExists(atPath: directory.path), "callback no IO")
        now += 1000
        release.signal()
        let entries = journal.read()!
        let tokens = entries.filter { $0["s"] as? String == "token" }
        require(tokens.count == 4, "four token transitions")
        require(Set(tokens.compactMap { $0["reason"] as? String }) == Set(["first", "unchanged", "rotated", "registration_failed"]),
                "serial token reasons")
        require(entries.filter { $0["s"] as? String != "diagnosticLoss" }.allSatisfy { $0["t"] as? Int64 == capturedTime },
                "callback time retained")
        require(entries.last?["value"] as? Int == 1, "one rejected token counted")
        require(prefs.string(forKey: "push.diagnostics.token_digest") == NativePushJournal.hash("POISON_TOKEN_B"),
                "last successful token digest")
        require(!String(data: try! JSONSerialization.data(withJSONObject: entries), encoding: .utf8)!.contains("POISON_TOKEN"),
                "no raw token in records")
        require(!prefs.dictionaryRepresentation().description.contains("POISON_TOKEN"), "no raw token in prefs")
    }

    static func main() throws {
        // Watchdog даёт диагностируемый exit, а не вечный wait при регрессе.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            fputs("FAIL coordinated IO: watchdog\n", stderr); exit(2)
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--hold-directory" {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: URL(fileURLWithPath: CommandLine.arguments[2]), options: [], error: &error
            ) { _ in
                FileHandle.standardOutput.write(Data([82]))
                require(FileHandle.standardInput.readData(ofLength: 1).count == 1, "holder release")
            }
            require(error == nil, "child grant")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coordinated-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = NativePushJournal(directory: directory)
        require(journal.append(.nseReceived), "initial write")
        let suite = "coordinated-token-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        waitsForGrant(directory, "append") { require(journal.append(.nseCompleted), "append succeeds") }
        waitsForGrant(directory, "read JSON") { require(journal.read() != nil, "read succeeds") }
        waitsForGrant(directory, "token") { journal.token("POISON_TOKEN", preferences: prefs) }
        holdsUntilBodyEnds(directory, "read JSON", pauseAt: 1) { require($0.read() != nil, "retained read") }
        holdsUntilBodyEnds(directory, "append", pauseAt: 2) { require($0.append(.nseReceived), "retained append") }
        holdsUntilBodyEnds(directory, "token", pauseAt: 2) { $0.token("POISON_TOKEN_B", preferences: prefs) }
        try modernProcesses(directory)
        try cancellation(directory)
        try scopedURL(directory)
        queuedTokens(directory)
        print("NativePushJournal: actual Foundation gate/read/write/token/lifetime PASS")
        print("NativePushJournal: cancellation/recovery/scopedURL/sharedTokenQueue PASS")
    }
}
