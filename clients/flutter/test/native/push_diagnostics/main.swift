import Foundation
import Darwin

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
print("NativePushJournal: interprocess contention/loss/token retry PASS")
