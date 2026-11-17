import Foundation
import Darwin
import UserNotifications

// Рабочий подпроцесс для настоящего межпроцессного contention, не threads.
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--contend" {
    let writer = NativePushJournal(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
    for _ in 0..<100 { writer.append(.nseReceived) }
    exit(0)
}

// ledger:RL-push-native-diagnostics
// Компилируется вместе с РЕАЛЬНЫМ NativePushJournal.swift, не с репликой.
let base = FileManager.default.temporaryDirectory.appendingPathComponent("push-journal-tests-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: base) }
var now: Int64 = 1_800_000_000_000
let journal = NativePushJournal(directory: base, clock: { now })

// AC:RL-push-native-diagnostics/2 — stable id, исходное время, hash128; повтор
// чтения/новый экземпляр не удаляют данные и не создают новые receipt.
journal.append(.nseReceived, eventId: "$secret-message")
let first = journal.read()!
let restart = NativePushJournal(directory: base, clock: { now })
assert(first.count == 1 && first[0]["id"] as? String == restart.read()![0]["id"] as? String)
assert(first[0]["t"] as? Int64 == now)
assert((first[0]["event_hash"] as! String).count == 32)
let serializedFirst = try JSONSerialization.data(withJSONObject: first)
assert(!String(data: serializedFirst, encoding: .utf8)!.contains("secret-message"))
var poisoned = first[0]
poisoned["hash_version"] = "POISON_TOKEN"
poisoned["payload"] = "POISON_TOKEN"
let poisonedData = try JSONSerialization.data(withJSONObject: poisoned)
try poisonedData.write(to: base.appendingPathComponent((first[0]["id"] as! String) + ".json"))
let sanitizedData = try JSONSerialization.data(withJSONObject: journal.read()!)
assert(!String(data: sanitizedData, encoding: .utf8)!.contains("POISON_TOKEN"))

// AC:RL-push-native-diagnostics/3 — count/bytes bound и явный cumulative loss.
for _ in 0..<300 { journal.append(.nseCompleted) }
let capped = journal.read()!
assert(capped.filter { $0["s"] as? String != "diagnosticLoss" }.count == 256)
assert((capped.last!["value"] as! Int) == 45)
let files = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.fileSizeKey])
let byteCount = try files.filter { $0.pathExtension == "json" }.reduce(0) {
    $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
}
assert(byteCount <= NativePushJournal.maxBytes)
now += NativePushJournal.ttlMs + 1
assert(journal.read()!.filter { $0["s"] as? String != "diagnosticLoss" }.isEmpty)
assert((journal.read()!.last!["value"] as! Int) == 301)

// AC:RL-push-native-diagnostics/4 — corruption не падает, не экспортирует текст.
try Data("{poison:secret}".utf8).write(to: base.appendingPathComponent("bad.json"))
assert((journal.read()!.last!["value"] as! Int) == 302)
let huge = base.appendingPathComponent("huge.json")
try Data(repeating: 65, count: 200_000).write(to: huge)
assert((journal.read()!.last!["value"] as! Int) == 303)
// Недоступное хранилище явно unknown (nil), вызов append не бросает.
let blocked = base.appendingPathComponent("blocked")
try Data().write(to: blocked)
let unavailable = NativePushJournal(directory: blocked)
unavailable.append(.nseReceived)
assert(unavailable.read() == nil)
print("NativePushJournal: stable/restart/privacy/count/bytes/TTL/corruption/storage PASS")
// AC:RL-push-native-diagnostics/6 — first/unchanged/rotated без raw token.
let suite = "native-token-test-" + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
journal.token("POISON_TOKEN_A", preferences: prefs)
journal.token("POISON_TOKEN_A", preferences: prefs)
journal.token("POISON_TOKEN_B", preferences: prefs)
journal.append(.token, reason: .registration_failed)
let tokenEntries = journal.read()!.filter { $0["s"] as? String == "token" }
assert(Set(tokenEntries.compactMap { $0["reason"] as? String }) == Set(["first", "unchanged", "rotated", "registration_failed"]))
let serializedTokens = try JSONSerialization.data(withJSONObject: tokenEntries)
assert(!String(data: serializedTokens, encoding: .utf8)!.contains("POISON_TOKEN"))
assert(!prefs.dictionaryRepresentation().description.contains("POISON_TOKEN"))
print("NativePushJournal: token lifecycle/privacy PASS")

// AC:RL-push-native-diagnostics/8 — реальный flock второго экземпляра и два
// процесса. Пропущенные append durable counted, token fingerprint не сдвинут.
let beforeContention = journal.read()!.last!["value"] as! Int
let held = open(base.appendingPathComponent("journal.lock").path, O_RDWR)
assert(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0)
let oldDigest = prefs.string(forKey: "push.diagnostics.token_digest")
journal.token("POISON_TOKEN_C", preferences: prefs)
assert(prefs.string(forKey: "push.diagnostics.token_digest") == oldDigest)
let workers = (0..<2).map { _ -> Process in
    let worker = Process()
    worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    worker.arguments = ["--contend", base.path]
    return worker
}
for worker in workers { try worker.run() }
for worker in workers { worker.waitUntilExit(); assert(worker.terminationStatus == 0) }
assert(flock(held, LOCK_UN) == 0)
close(held)
let afterContention = restart.read()!.last!["value"] as! Int
assert(afterContention == beforeContention + 201)
let counterSize = try base.appendingPathComponent("contention.count").resourceValues(forKeys: [.fileSizeKey]).fileSize
assert(counterSize == 8)
journal.token("POISON_TOKEN_C", preferences: prefs)
assert(prefs.string(forKey: "push.diagnostics.token_digest") != oldDigest)
// AC:RL-push-test-sender-and-acks/9 — момент отправки Sygnal'ом (`liza_sent_ms`)
// переживает запись и чистку; мусор отбрасывается.
assert(NativePushJournal.sentMs(NSNumber(value: 1_799_999_999_000)) == 1_799_999_999_000)
assert(NativePushJournal.sentMs("1799999999000") == 1_799_999_999_000)
assert(NativePushJournal.sentMs("soon") == nil && NativePushJournal.sentMs(-5) == nil && NativePushJournal.sentMs(nil) == nil)
let sentBase = FileManager.default.temporaryDirectory.appendingPathComponent("push-journal-sent-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: sentBase) }
let sentJournal = NativePushJournal(directory: sentBase, clock: { now })
sentJournal.append(.nseReceived, eventId: "$e1", sent: now - 1500)
sentJournal.append(.nseCompleted, eventId: "$e1")
let sentRead = sentJournal.read()!
assert(sentRead.first { $0["s"] as? String == "nseReceived" }?["sent"] as? Int64 == now - 1500)
assert(sentRead.first { $0["s"] as? String == "nseCompleted" }?["sent"] == nil)
print("NativePushJournal: interprocess contention/loss/token retry PASS")

// AC:RL-push-native-diagnostics/10 — реальные Context/append/read: один event,
// разные account/request, stable process run, тип входа отдельно actual render.
let traceDir = base.appendingPathComponent("trace")
let trace = NativePushJournal(directory: traceDir, clock: { now })
let dispatch = UUID().uuidString
var info: [AnyHashable: Any] = ["event_id": "$private-event", "client_name": "private-account",
    "content": ["msgtype": "m.audio", "voice": true, "body": "PRIVATE_FILENAME"],
    "sender_display_name": "PRIVATE_NAME", "liza_dispatch_id": dispatch, "liza_dispatch_attempt": 2]
let context = NativePushJournal.context(info, requestId: "private-request")
assert(context.media == .voice && context.shape == .object && context.recipe == .unknown)
assert(context.render == .apnsOriginal && context.dispatchId == dispatch && context.dispatchAttempt == 2)
trace.append(.received, context: context)
info["client_name"] = "another-account"
let other = NativePushJournal.context(info, requestId: "another-request", source: .local, render: .nativeFormatted)
trace.append(.localSubmission, context: other)
trace.append(.removalRequested, context: context, matchedRequestIds: (0..<12).map { "private-request-\($0)" })
let observations = trace.read()!
let received = observations.first { $0["s"] as? String == "received" }!
let submitted = observations.first { $0["s"] as? String == "localSubmission" }!
assert(received["event_hash"] as? String == submitted["event_hash"] as? String)
assert(received["account_hash"] as? String != submitted["account_hash"] as? String)
assert(received["request_hash"] as? String != submitted["request_hash"] as? String)
assert(received["run_id"] as? String == submitted["run_id"] as? String)
assert(received["run_id"] as? String == NativePushJournal.processRunId)
assert(received["render_recipe"] as? String == "unknown" && submitted["render_recipe"] as? String == "body")
let removal = observations.first { $0["s"] as? String == "removalRequested" }!
assert(removal["matched_count"] as? Int == 12)
assert((removal["matched_request_hashes"] as? [String])?.count == 8)
assert(removal["matches_truncated"] as? Bool == true)
let traceText = String(data: try JSONSerialization.data(withJSONObject: observations), encoding: .utf8)!
for secret in ["private-", "another-account", "PRIVATE_"] { assert(!traceText.contains(secret)) }
assert(Set(trace.read()!.compactMap { $0["id"] as? String }) == Set(observations.compactMap { $0["id"] as? String }))
assert(NativePushJournal.context(["liza_dispatch_attempt": true]).dispatchAttempt == nil)
assert(NativePushJournal.context(["liza_dispatch_attempt": 1.5]).dispatchAttempt == nil)
let plugin = NativePushJournal.context(["payload": "account|!room|$event"], requestId: "42", source: .local, render: .dartLocal)
assert(plugin.eventId == "$event" && plugin.accountId == "account" && plugin.requestId == "42")
assert(NativePushJournal.context(["content": "{\"msgtype\":\"m.audio\",\"voice\":false}"]).media == .audio)
print("NativePushJournal: account/request/run/media/render/dispatch/privacy/removal PASS")

// AC:RL-push-native-diagnostics/11 — реальный предикат retract: 0/1/2,
// соседнее событие той же комнаты и обычный plugin payload не удаляются.
func request(_ id: String, _ event: String?, payload: String? = nil) -> UNNotificationRequest {
    let c = UNMutableNotificationContent()
    c.userInfo = ["room_id": "!same-room"]
    if let event = event { c.userInfo["event_id"] = event }
    if let payload = payload { c.userInfo["payload"] = payload }
    return UNNotificationRequest(identifier: id, content: c, trigger: nil)
}
let target = "$target"
let candidates = [request("1", target), request("2", "$other"), request("3", target), request("4", nil, payload: "account|!same-room|$target")]
assert(NativePushJournal.matchingRequests([], eventId: target).isEmpty)
assert(NativePushJournal.matchingRequests(Array(candidates.prefix(2)), eventId: target).map { $0.identifier } == ["1"])
assert(NativePushJournal.matchingRequests(candidates, eventId: target).map { $0.identifier } == ["1", "3"])
print("NativePushJournal: unchanged retract predicate 0/1/2 PASS")

// AC:RL-push-native-diagnostics/13 — production bounded queue, capture time,
// no IO до возврата callback, reader barrier, durable backlog drop count.
let asyncDir = base.appendingPathComponent("async")
let asyncJournal = NativePushJournal(directory: asyncDir, clock: { now })
let heldQueue = DispatchSemaphore(value: 0)
let enteredQueue = DispatchSemaphore(value: 0)
NativePushJournal.writerQueue.async { enteredQueue.signal(); heldQueue.wait() }
assert(enteredQueue.wait(timeout: .now() + 2) == .success)
let capturedTime = now
let admitted = (0..<70).map { _ in asyncJournal.enqueue(.received, context: context) }
assert(admitted.filter { $0 }.count == NativePushJournal.maxPending)
assert(!FileManager.default.fileExists(atPath: asyncDir.path), "callback must not perform disk IO")
now += 1000
heldQueue.signal()
let asyncEntries = asyncJournal.read()!
let asyncObservations = asyncEntries.filter { $0["s"] as? String == "received" }
assert(asyncObservations.count == 64)
assert(asyncObservations.allSatisfy { $0["t"] as? Int64 == capturedTime && $0["capture_policy"] as? String == "async_best_effort" })
assert(asyncEntries.last!["value"] as? Int == 6)
assert(Set(asyncJournal.read()!.compactMap { $0["id"] as? String }) == Set(asyncEntries.compactMap { $0["id"] as? String }))
assert(NativePushJournal.context(["content": ["msgtype": "m.sticker"], "sender_display_name": "private"], render: .nseFormatted).recipe == .mediaLabel)
assert(NativePushJournal.context(["content": ["msgtype": "m.audio"]], render: .nativeFormatted).render == .apnsOriginal)
print("NativePushJournal: bounded async/capture/barrier/loss/actual recipe PASS")

// AC:RL-push-native-diagnostics/13 — временный отказ до получения lock не
// исчезает из истории после восстановления каталога; counted ровно один раз.
let transientPath = base.appendingPathComponent("transient-storage")
try Data().write(to: transientPath)
let transient = NativePushJournal(directory: transientPath, clock: { now })
assert(transient.enqueue(.received, context: context))
assert(transient.read() == nil)
try FileManager.default.removeItem(at: transientPath)
let recovered = transient.read()!
assert(recovered.count == 1 && recovered[0]["s"] as? String == "diagnosticLoss")
assert(recovered[0]["value"] as? Int == 1)
assert(transient.read()![0]["value"] as? Int == 1)
print("NativePushJournal: recovered storage failure explicit exactly-once loss PASS")

let transientLock = open(transientPath.appendingPathComponent("journal.lock").path, O_RDWR)
assert(transientLock >= 0 && flock(transientLock, LOCK_EX | LOCK_NB) == 0)
assert(transient.enqueue(.received, context: context))
NativePushJournal.writerQueue.sync {} // ждёт writer только тест, не callback
assert(flock(transientLock, LOCK_UN) == 0)
close(transientLock)
assert(transient.read()!.last!["value"] as? Int == 2, "async contention must add one loss, not two")
print("NativePushJournal: async lock contention counted once PASS")

// AC:RL-push-native-diagnostics/10 — raw requested flags, не звук/видимость ОС.
let optionsJournal = NativePushJournal(directory: base.appendingPathComponent("presentation"), clock: { now })
let masks: [UInt] = [0, 1, UNNotificationPresentationOptions.sound.rawValue,
    UNNotificationPresentationOptions([.banner, .sound, .list]).rawValue, 65535]
for mask in masks { assert(optionsJournal.enqueue(.presentation, context: context, presentationOptions: mask)) }
assert(optionsJournal.enqueue(.presentation, context: context, presentationOptions: 65536))
assert(optionsJournal.enqueue(.presentation, context: context, presentationOptions: UInt.max))
let optionsEntries = optionsJournal.read()!
assert(optionsEntries.count == 7)
assert(optionsEntries.compactMap { $0["presentation_options"] as? Int }.sorted() == masks.map { Int($0) }.sorted())
assert(optionsEntries.filter { $0["presentation_options"] == nil }.count == 2)
var invalidOptions = optionsEntries.first!
invalidOptions["presentation_options"] = -1
try JSONSerialization.data(withJSONObject: invalidOptions).write(to: optionsJournal.directory.appendingPathComponent((invalidOptions["id"] as! String) + ".json"))
assert(optionsJournal.read()!.first { $0["id"] as? String == invalidOptions["id"] as? String }?["presentation_options"] == nil)
print("NativePushJournal: requested presentation mask bounds/projection PASS")
