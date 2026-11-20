import Foundation
import CryptoKit
import Darwin
import CoreFoundation
import UserNotifications

/// Независимый App Group spool: отдельный атомарный файл на запись, а не
/// UserDefaults read-modify-write. Доступ Runner/NSE координируется Foundation:
/// iOS защищает предоставленный accessor от suspension. Callback только enqueue.
/// В журнал никогда не попадает payload/token.
final class NativePushJournal {
    enum Stage: String, Codable {
        case received, localSubmission, localResult, presentation, deliveredObserved, removalRequested, removalObservedAbsent
        case nseReceived, nseCompleted, nseExpired, nseError, nseSwept, nseSuppressed, fcmReceived, token, diagnosticLoss
    }
    enum Reason: String, Codable { case first, unchanged, rotated, registration_failed, storage, dropped }
    enum Media: String, Codable { case unknown, text, audio, voice, image, video, file, encrypted, other }
    enum Shape: String, Codable { case absent, object, json, invalid }
    enum RenderSource: String, Codable { case apnsOriginal, nseFormatted, nativeFormatted, dartLocal, unknown }
    enum Recipe: String, Codable { case unknown, body, mediaLabel, encryptedFallback, genericFallback, empty }
    enum Source: String, Codable { case remote, local, unknown }
    enum Outcome: String, Codable { case accepted, failed, skipped, suppressed, bannerSoundList, soundList, plugin, unknown }
    enum CapturePolicy: String, Codable { case sync, async_best_effort }
    enum Role: String, Codable { case runner, nse }
    // Один UUID на процесс, а не на создаваемый shared экземпляр.
    static let processRunId = UUID().uuidString
    struct Context {
        var eventId: String?
        var accountId: String?
        var requestId: String?
        var media: Media = .unknown
        var voice: Bool?
        var shape: Shape = .absent
        var render: RenderSource = .unknown
        var recipe: Recipe = .unknown
        var source: Source = .unknown
        var dispatchId: String?
        var dispatchAttempt: Int?
        var sent: Int64?
    }

    /// Классификация входа без сохранения body, имени файла и raw идентификаторов.
    static func context(_ info: [AnyHashable: Any], requestId: String? = nil,
                        source: Source = .remote, render: RenderSource = .apnsOriginal) -> Context {
        var context = Context(eventId: info["event_id"] as? String,
                              accountId: info["client_name"] as? String, requestId: requestId)
        context.source = source; context.render = render
        if source == .local, let payload = info["payload"] as? String {
            let parts = payload.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count == 3 { context.accountId = String(parts[0]); context.eventId = String(parts[2]) }
        }
        var content: [String: Any]?
        if let object = info["content"] as? [String: Any] { content = object; context.shape = .object }
        else if let string = info["content"] as? String, string.utf8.count <= 4096,
                let data = string.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            content = object; context.shape = .json
        } else if info["content"] != nil { context.shape = .invalid }
        context.voice = content?["voice"] as? Bool
        switch content?["msgtype"] as? String {
        case "m.audio": context.media = context.voice == true ? .voice : .audio
        case "m.text", "m.notice", "m.emote": context.media = .text
        case "m.image": context.media = .image
        case "m.video": context.media = .video
        case "m.file": context.media = .file
        case .some: context.media = .other
        case nil: break
        }
        if info["type"] as? String == "m.room.encrypted" { context.media = .encrypted }
        // Recipe описывает только реально форматируемый контент. Для оригинала
        // APNs локальная ветка форматирования не является доказательством.
        if render == .nseFormatted || render == .nativeFormatted {
            if render == .nativeFormatted && info["sender_display_name"] as? String == nil && info["type"] as? String != "m.room.member" {
                context.render = .apnsOriginal; context.recipe = .unknown
            }
            else if render == .nativeFormatted && info["type"] as? String == "m.room.member" { context.recipe = .unknown }
            else if info["sender_display_name"] as? String == nil { context.recipe = .genericFallback }
            else if context.media == .encrypted { context.recipe = .encryptedFallback }
            else if content?["body"] is String { context.recipe = .body }
            else if [.audio, .voice, .image, .video, .file].contains(context.media) || content?["msgtype"] as? String == "m.sticker" { context.recipe = .mediaLabel }
            else { context.recipe = .genericFallback }
        }
        context.dispatchId = (info["liza_dispatch_id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }
        if let n = info["liza_dispatch_attempt"] as? NSNumber,
           CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.int64Value),
           n.int64Value >= 0, n.int64Value <= 2147483647 { context.dispatchAttempt = n.intValue }
        context.sent = sentMs(info["liza_sent_ms"])
        return context
    }

    /// Предикат старого retract: только event_id; локальный payload не матчится.
    static func matchingRequests(_ requests: [UNNotificationRequest], eventId: String) -> [UNNotificationRequest] {
        requests.filter { ($0.content.userInfo["event_id"] as? String) == eventId }
    }

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
        var account_hash: String?
        var request_hash: String?
        var run_id: String?
        var process_role: Role?
        var capture_policy: CapturePolicy?
        var observed_build: String?
        var media: Media?
        var voice: Bool?
        var content_shape: Shape?
        var render_source: RenderSource?
        var render_recipe: Recipe?
        var source: Source?
        var dispatch_id: String?
        var dispatch_attempt: Int?
        var outcome: Outcome?
        var presentation_options: Int?
        var observed_date: Int64?
        var matched_count: Int?
        var matched_request_hashes: [String]?
        var matches_truncated: Bool?
    }
    static let maxEntryBytes = 2048
    static let maxMatchedRequests = 8
    static let maxCount = 256
    static let maxBytes = 128 * 1024
    static let ttlMs: Int64 = 7 * 24 * 60 * 60 * 1000
    let directory: URL
    private let clock: () -> Int64
    private let makeCoordinator: () -> NSFileCoordinator
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         makeCoordinator: @escaping () -> NSFileCoordinator = { NSFileCoordinator(filePresenter: nil) }) {
        self.directory = directory
        self.clock = clock
        self.makeCoordinator = makeCoordinator
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

    // Очередь ограничена процессом: shared создаёт новый объект, но не новый budget.
    static let writerQueue = DispatchQueue(label: "Liza.NativePushJournal", qos: .utility)
    static let maxPending = 64
    private static let pendingLock = NSLock()
    private static var pending = 0
    private static var queueLoss: Int64 = 0

    /// На callback только immutable capture + bounded enqueue, никакого file IO.
    /// Возврат true означает pending; смерть процесса до writer оставляет gap.
    @discardableResult
    func enqueue(_ stage: Stage, eventId: String? = nil, reason: Reason? = nil, value: Int? = nil,
                sent: Int64? = nil, context: Context? = nil, outcome: Outcome? = nil,
                presentationOptions: UInt? = nil, observedDate: Date? = nil, matchedRequestIds: [String]? = nil) -> Bool {
        var entry = capture(stage, eventId: eventId, reason: reason, value: value, sent: sent,
                              context: context, outcome: outcome, presentationOptions: presentationOptions, observedDate: observedDate,
                              matchedRequestIds: matchedRequestIds)
        entry.capture_policy = .async_best_effort
        let captured = entry
        return submit { self.write(captured, deferLoss: true) }
    }

    /// APNs callback не ждёт coordination и не передаёт raw token в очередь.
    /// Сравнение fingerprint последовательно с записью, время — исходного callback.
    @discardableResult
    func enqueueToken(_ token: String, preferences prefs: UserDefaults = .standard) -> Bool {
        let digest = Self.hash(token)
        var entry = capture(.token)
        entry.capture_policy = .async_best_effort
        let captured = entry
        return submit {
            let key = "push.diagnostics.token_digest"
            let old = prefs.string(forKey: key)
            var entry = captured
            entry.reason = old == nil ? .first : (old == digest ? .unchanged : .rotated)
            guard self.write(entry, deferLoss: true) else { return false }
            prefs.set(digest, forKey: key)
            return true
        }
    }

    private func submit(_ work: @escaping () -> Bool) -> Bool {
        guard Self.pendingLock.try() else {
            OSAtomicIncrement64Barrier(&Self.queueLoss); return false
        }
        guard Self.pending < Self.maxPending else {
            Self.pendingLock.unlock()
            OSAtomicIncrement64Barrier(&Self.queueLoss); return false
        }
        Self.pending += 1
        Self.pendingLock.unlock()
        Self.writerQueue.async {
            if !work() {
                // Единственный счётчик async failure: включает недоступный
                // каталог/open. Не удваиваем spool contention/write loss.
                OSAtomicIncrement64Barrier(&Self.queueLoss)
            }
            self.flushQueueLoss()
            Self.pendingLock.lock()
            Self.pending -= 1
            Self.pendingLock.unlock()
        }
        return true
    }

    /// Синхронный spool primitive для host проверки и token fingerprint.
    @discardableResult
    func append(_ stage: Stage, eventId: String? = nil, reason: Reason? = nil, value: Int? = nil,
                sent: Int64? = nil, context: Context? = nil, outcome: Outcome? = nil,
                presentationOptions: UInt? = nil, observedDate: Date? = nil, matchedRequestIds: [String]? = nil) -> Bool {
        write(capture(stage, eventId: eventId, reason: reason, value: value, sent: sent,
                              context: context, outcome: outcome, presentationOptions: presentationOptions, observedDate: observedDate,
                              matchedRequestIds: matchedRequestIds))
    }

    private func capture(_ stage: Stage, eventId: String? = nil, reason: Reason? = nil, value: Int? = nil,
                sent: Int64? = nil, context: Context? = nil, outcome: Outcome? = nil,
                presentationOptions: UInt? = nil, observedDate: Date? = nil, matchedRequestIds: [String]? = nil) -> Entry {
            let eventHash = (context?.eventId ?? eventId).flatMap { $0.isEmpty ? nil : Self.hash($0) }
            var entry = Entry(id: UUID().uuidString, t: clock(), s: stage, reason: reason,
                              event_hash: eventHash, hash_version: eventHash == nil ? nil : "sha256-128",
                              value: value, sent: (context?.sent ?? sent).flatMap { $0 > 0 ? $0 : nil })
            entry.capture_policy = .sync
            entry.run_id = Self.processRunId
            entry.process_role = Bundle.main.bundleURL.pathExtension == "appex" ? .nse : .runner
            entry.observed_build = Self.build(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            if let c = context {
                entry.account_hash = c.accountId.flatMap { $0.isEmpty ? nil : Self.hash($0) }
                entry.request_hash = c.requestId.flatMap { $0.isEmpty ? nil : Self.hash($0) }
                entry.media = c.media; entry.voice = c.voice; entry.content_shape = c.shape
                entry.render_source = c.render; entry.render_recipe = c.recipe; entry.source = c.source
                entry.dispatch_id = c.dispatchId.flatMap { UUID(uuidString: $0)?.uuidString }
                entry.dispatch_attempt = c.dispatchAttempt.flatMap { (0...2147483647).contains($0) ? $0 : nil }
            }
            entry.outcome = outcome
            entry.presentation_options = presentationOptions.flatMap { $0 <= 65535 ? Int($0) : nil }
            entry.observed_date = observedDate.map { Int64($0.timeIntervalSince1970 * 1000) }
            if let ids = matchedRequestIds {
                entry.matched_count = ids.count
                entry.matched_request_hashes = ids.prefix(Self.maxMatchedRequests).map(Self.hash)
                entry.matches_truncated = ids.count > Self.maxMatchedRequests
            }
            return entry
    }

    private func write(_ entry: Entry, deferLoss: Bool = false) -> Bool {
        locked(fallback: false, reportLoss: !deferLoss) { directory in
            do {
                let data = try encoder.encode(entry)
                guard data.count <= Self.maxEntryBytes else {
                    if !deferLoss { addLoss(1, in: directory) }
                    return false
                }
                try data.write(to: directory.appendingPathComponent(entry.id + ".json"), options: .atomic)
            } catch {
                if !deferLoss { addLoss(1, in: directory) }
                return false
            }
            _ = retained(in: directory)
            return true
        }
    }

    private func flushQueueLoss() {
        let count = OSAtomicAdd64Barrier(0, &Self.queueLoss)
        guard count > 0 else { return }
        let persisted = locked(fallback: false) { directory -> Bool in
            return addLoss(Int(min(count, 2147483647)), in: directory)
        }
        if persisted { _ = OSAtomicAdd64Barrier(-count, &Self.queueLoss) }
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
        // Вызывается bridge с utility queue. Callback не использует barrier.
        Self.writerQueue.sync { flushQueueLoss() }
        return locked(fallback: nil) { directory in
            var entries = retained(in: directory).map { $0.1 }
            let loss = lossCount(in: directory)
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

    private func locked<T>(fallback: T, reportLoss: Bool = false, _ body: (URL) -> T) -> T {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(resource)
        } catch { return fallback }
        var result = fallback
        var accessed = false
        var error: NSError?
        // Новый coordinator на операцию, без общего purposeIdentifier/presenter.
        // При grant Foundation даёт background task Runner И NSE. Без него iOS
        // может убить suspended процесс, удерживающий flock (0xdead10cc).
        makeCoordinator().coordinate(writingItemAt: directory, options: [], error: &error) { scopedDirectory in
            accessed = true
            let fd = open(scopedDirectory.appendingPathComponent("journal.lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            // Совместимость с участником старой версии, ещё не использующим
            // coordination. Lock и весь IO завершаются ДО возврата accessor.
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if reportLoss { _ = concurrentLoss(in: scopedDirectory, increment: true) }
                return
            }
            defer { flock(fd, LOCK_UN) }
            result = body(scopedDirectory)
        }
        // Отмена до grant: не пытаться писать loss вне защищённого scope.
        // Async failure уже считает submit; failed flush сохраняет свой backlog.
        if !accessed && reportLoss { OSAtomicIncrement64Barrier(&Self.queueLoss) }
        return result
    }

    /// Фиксированные 8 байт вместо массива loss-файлов. mmap + системный atomic
    /// работают между NSE/Runner процессами без ожидания journal.lock. msync
    /// сохраняет счётчик до возврата writer; сам callback не ждёт чужой lock.
    private func concurrentLoss(in directory: URL, increment: Bool = false) -> Int {
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

    private func lossCount(in directory: URL) -> Int {
        min(2147483647, baseLossCount(in: directory) + concurrentLoss(in: directory))
    }
    private func baseLossCount(in directory: URL) -> Int {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("loss.count")),
              let raw = String(data: data, encoding: .utf8), let n = Int(raw) else { return 0 }
        return max(0, min(2147483647, n))
    }
    @discardableResult
    private func addLoss(_ count: Int, in directory: URL) -> Bool {
        guard count > 0 else { return true }
        let data = Data(String(min(2147483647, baseLossCount(in: directory) + count)).utf8)
        do {
            try data.write(to: directory.appendingPathComponent("loss.count"), options: .atomic)
            return true
        } catch { return false }
    }

    private static func digest(_ value: String?) -> String? {
        guard let v = value, v.count == 32, v.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return v
    }
    private static func build(_ value: String?) -> String? {
        guard let v = value, !v.isEmpty, v.count <= 32, v.allSatisfy({ "0123456789.".contains($0) }) else { return nil }
        return v
    }

    private func retained(in directory: URL) -> [(URL, Entry, Int)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var entries: [(URL, Entry, Int)] = []
        var dropped = 0
        let now = clock()
        for file in files where file.pathExtension == "json" {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= Self.maxEntryBytes,
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
            var clean = Entry(id: entry.id, t: entry.t, s: entry.s, reason: entry.reason,
                              event_hash: entry.event_hash,
                              hash_version: entry.event_hash == nil ? nil : "sha256-128",
                              value: entry.value.map { max(0, min(2147483647, $0)) },
                              sent: entry.sent.flatMap { $0 > 0 && $0 <= now + Self.ttlMs ? $0 : nil })
            clean.account_hash = Self.digest(entry.account_hash)
            clean.request_hash = Self.digest(entry.request_hash)
            clean.run_id = entry.run_id.flatMap { UUID(uuidString: $0)?.uuidString }
            clean.capture_policy = entry.capture_policy
            clean.process_role = entry.process_role; clean.observed_build = Self.build(entry.observed_build)
            clean.media = entry.media; clean.voice = entry.voice; clean.content_shape = entry.content_shape
            clean.render_source = entry.render_source; clean.render_recipe = entry.render_recipe; clean.source = entry.source
            clean.dispatch_id = entry.dispatch_id.flatMap { UUID(uuidString: $0)?.uuidString }
            clean.dispatch_attempt = entry.dispatch_attempt.flatMap { (0...2147483647).contains($0) ? $0 : nil }
            clean.outcome = entry.outcome
            clean.presentation_options = entry.presentation_options.flatMap { (0...65535).contains($0) ? $0 : nil }
            clean.observed_date = entry.observed_date.flatMap { $0 > 0 && $0 <= now + 60000 ? $0 : nil }
            clean.matched_count = entry.matched_count.flatMap { (0...2147483647).contains($0) ? $0 : nil }
            clean.matched_request_hashes = entry.matched_request_hashes.map { Array($0.prefix(Self.maxMatchedRequests).compactMap(Self.digest)) }
            clean.matches_truncated = entry.matches_truncated
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
        addLoss(dropped, in: directory)
        return entries
    }
}
