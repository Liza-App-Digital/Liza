import Foundation
import CryptoKit
import Darwin

/// Независимый App Group spool: отдельный атомарный файл на запись, а не
/// UserDefaults read-modify-write. Lock общий у extension и Runner; contention
/// не блокирует contentHandler. В журнал никогда не попадает payload/token.
final class NativePushJournal {
    enum Stage: String, Codable {
        case nseReceived, nseCompleted, nseExpired, nseError, nseSwept, nseSuppressed, fcmReceived, token, diagnosticLoss
    }
    enum Reason: String, Codable { case first, unchanged, rotated, registration_failed, storage, dropped }
    struct Entry: Codable {
        let id: String
        let t: Int64
        let s: Stage
        var reason: Reason?
        var event_hash: String?
        var hash_version: String?
        var value: Int?
        /// M6: момент отправки Sygnal'ом (`liza_sent_ms` в пуше), мс эпохи.
        var sent: Int64?
    }
    static let maxCount = 256
    static let maxBytes = 128 * 1024
    static let ttlMs: Int64 = 7 * 24 * 60 * 60 * 1000
    let directory: URL
    private let clock: () -> Int64
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.directory = directory
        self.clock = clock
    }

    static var shared: NativePushJournal? {
        #if os(iOS)
        guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
        let appId = Bundle.main.bundleURL.pathExtension == "appex"
            ? bundleId.split(separator: ".").dropLast().joined(separator: ".") : bundleId
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group." + appId) else { return nil }
        #else
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let root = base.appendingPathComponent("Liza", isDirectory: true)
        #endif
        return NativePushJournal(directory: root.appendingPathComponent("push-diagnostics-v2", isDirectory: true))
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// `liza_sent_ms` из userInfo (число или строка) → мс; мусор → nil.
    static func sentMs(_ raw: Any?) -> Int64? {
        let value: Int64?
        switch raw {
        case let n as NSNumber: value = n.int64Value
        case let s as String: value = Int64(s)
        default: value = nil
        }
        guard let v = value, v > 0 else { return nil }
        return v
    }

    @discardableResult
    func append(_ stage: Stage, eventId: String? = nil, reason: Reason? = nil, value: Int? = nil,
                sent: Int64? = nil) -> Bool {
        locked(fallback: false, reportLoss: true) {
            let eventHash = eventId.flatMap { $0.isEmpty ? nil : Self.hash($0) }
            let entry = Entry(id: UUID().uuidString, t: clock(), s: stage, reason: reason,
                              event_hash: eventHash, hash_version: eventHash == nil ? nil : "sha256-128",
                              value: value, sent: sent.flatMap { $0 > 0 ? $0 : nil })
            do {
                let data = try encoder.encode(entry)
                try data.write(to: directory.appendingPathComponent(entry.id + ".json"), options: .atomic)
            } catch { addLoss(1); return false }
            _ = retained()
            return true
        }
    }

    /// Храним только необратимый digest; token не является диагностикой.
    func token(_ token: String, preferences prefs: UserDefaults = .standard) {
        let key = "push.diagnostics.token_digest"
        let digest = Self.hash(token)
        let old = prefs.string(forKey: key)
        let reason: Reason = old == nil ? .first : (old == digest ? .unchanged : .rotated)
        if append(.token, reason: reason) {
            prefs.set(digest, forKey: key)
        }
    }

    /// Non-destructive: outbox может упасть после чтения; повтор отдаст те же id.
    func read() -> [[String: Any]]? {
        locked(fallback: nil) {
            var entries = retained().map { $0.1 }
            let loss = lossCount()
            if loss > 0 {
                entries.append(Entry(id: "native-diagnostic-loss", t: clock(), s: .diagnosticLoss,
                                     reason: .dropped, value: loss))
            }
            return entries.compactMap { entry in
                guard let data = try? encoder.encode(entry) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
    }

    private func locked<T>(fallback: T, reportLoss: Bool = false, _ body: () -> T) -> T {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(resource)
        } catch { return fallback }
        let fd = open(directory.appendingPathComponent("journal.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return fallback }
        defer { close(fd) }
        // Файловый I/O выполняется с вне-UI очереди Reader; writer не ждёт lock.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if reportLoss { _ = concurrentLoss(increment: true) }
            return fallback
        }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    /// Фиксированные 8 байт вместо массива loss-файлов. mmap + системный atomic
    /// работают между NSE/Runner процессами без ожидания journal.lock. msync
    /// сохраняет счётчик до возврата writer; сам callback не ждёт чужой lock.
    private func concurrentLoss(increment: Bool = false) -> Int {
        let path = directory.appendingPathComponent("contention.count").path
        let fd = open(path, increment ? O_CREAT | O_RDWR : O_RDWR, 0o600)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        guard ftruncate(fd, 8) == 0,
              let memory = mmap(nil, 8, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              memory != MAP_FAILED else { return 0 }
        defer { munmap(memory, 8) }
        let counter = memory.assumingMemoryBound(to: Int64.self)
        var value = OSAtomicAdd64Barrier(0, counter)
        if increment {
            while value >= 0 && value < 2147483647 {
                if OSAtomicCompareAndSwap64Barrier(value, value + 1, counter) {
                    value += 1
                    break
                }
                value = OSAtomicAdd64Barrier(0, counter)
            }
            _ = msync(memory, 8, MS_SYNC)
        }
        return Int(max(0, min(2147483647, value)))
    }

    private func lossCount() -> Int {
        min(2147483647, baseLossCount() + concurrentLoss())
    }
    private func baseLossCount() -> Int {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("loss.count")),
              let raw = String(data: data, encoding: .utf8), let n = Int(raw) else { return 0 }
        return max(0, min(2147483647, n))
    }
    private func addLoss(_ count: Int) {
        guard count > 0 else { return }
        let data = Data(String(min(2147483647, baseLossCount() + count)).utf8)
        try? data.write(to: directory.appendingPathComponent("loss.count"), options: .atomic)
    }

    private func retained() -> [(URL, Entry, Int)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var entries: [(URL, Entry, Int)] = []
        var dropped = 0
        let now = clock()
        for file in files where file.pathExtension == "json" {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= 1024,
                  let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(Entry.self, from: data),
                  UUID(uuidString: entry.id) != nil,
                  entry.t >= now - Self.ttlMs, entry.t <= now + 60000,
                  entry.event_hash == nil || (entry.event_hash!.count == 32 && entry.event_hash!.allSatisfy { "0123456789abcdef".contains($0) }) else {
                try? FileManager.default.removeItem(at: file)
                dropped += 1
                continue
            }
            // Даже при повреждённом файле экспортируется закрытая проекция.
            let clean = Entry(id: entry.id, t: entry.t, s: entry.s, reason: entry.reason,
                              event_hash: entry.event_hash,
                              hash_version: entry.event_hash == nil ? nil : "sha256-128",
                              value: entry.value.map { max(0, min(2147483647, $0)) },
                              sent: entry.sent.flatMap { $0 > 0 && $0 <= now + Self.ttlMs ? $0 : nil })
            entries.append((file, clean, size))
        }
        entries.sort { $0.1.t == $1.1.t ? $0.1.id < $1.1.id : $0.1.t < $1.1.t }
        var bytes = entries.reduce(0) { $0 + $1.2 }
        while entries.count > Self.maxCount || bytes > Self.maxBytes {
            let removed = entries.removeFirst()
            bytes -= removed.2
            try? FileManager.default.removeItem(at: removed.0)
            dropped += 1
        }
        addLoss(dropped)
        return entries
    }
}
