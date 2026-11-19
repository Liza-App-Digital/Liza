import Foundation
import UserNotifications

/// Адрес доставленного запроса. FLN переиспользует числовой ID комнаты,
/// поэтому перед удалением повторно проверяем событие и владельца.
enum DeliveredBanner {
    static func metadata(_ info: [AnyHashable: Any]) -> (owner: String, room: String, event: String)? {
        var owner = info["client_name"] as? String ?? ""
        var room = info["room_id"] as? String ?? ""
        var event = info["event_id"] as? String ?? ""
        if let payload = info["payload"] as? String {
            let parts = payload.components(separatedBy: "|")
            guard parts.count == 3 else { return nil }
            let localOwner = parts[0] == "null" ? "" : parts[0]
            guard (owner.isEmpty || owner == localOwner), (room.isEmpty || room == parts[1]),
                  (event.isEmpty || event == parts[2]) else { return nil }
            owner = localOwner
            room = parts[1]
            event = parts[2]
        }
        guard !event.isEmpty, event != "null" else { return nil }
        return (owner, room, event)
    }

    static func descriptor(_ request: UNNotificationRequest) -> [String: String]? {
        guard let (owner, fromPayload, event) = metadata(request.content.userInfo) else { return nil }
        let room = fromPayload.isEmpty ? request.content.threadIdentifier : fromPayload
        guard !request.identifier.isEmpty, !room.isEmpty, room != "null" else { return nil }
        return ["requestId": request.identifier, "roomId": room, "eventId": event, "clientName": owner]
    }

    static func matching(_ requests: [UNNotificationRequest], reads: [[String: String]],
                         singleAccount: Bool) -> [UNNotificationRequest] {
        var byId = [String: [String: String]]()
        for read in reads {
            guard let id = read["requestId"], let reader = read["readBy"], !reader.isEmpty,
                  let owner = read["clientName"],
                  owner == reader || (owner.isEmpty && singleAccount) else { continue }
            var identity = read
            identity.removeValue(forKey: "readBy")
            byId[id] = identity
        }
        return requests.filter { request in
            guard let expected = byId[request.identifier] else { return false }
            return descriptor(request) == expected
        }
    }

    typealias ListRequests = (@escaping ([UNNotificationRequest]) -> Void) -> Void

    static func listRequests(_ done: @escaping ([UNNotificationRequest]) -> Void) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notes in done(notes.map { $0.request }) }
    }

    static func list(_ done: @escaping ([[String: String]]) -> Void) {
        listRequests { requests in done(requests.compactMap(descriptor)) }
    }

    /// В результат попадают только ранее наблюдавшиеся request ID, исчезнувшие
    /// из повторной системной выборки. Новая запись под тем же ID сохраняется.
    static func remove(_ reads: [[String: String]], singleAccount: Bool,
                       scopeIsCurrent: @escaping () -> Bool = { true },
                       listRequests: @escaping ListRequests = listRequests,
                       removeRequests: @escaping ([String]) -> Void = {
                           UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0)
                       }, done: @escaping ([String]) -> Void) {
        listRequests { requests in
            guard scopeIsCurrent() else { return done([]) }
            let selected = matching(requests, reads: reads, singleAccount: singleAccount)
            guard !selected.isEmpty else { return done([]) }
            let ids = selected.map { $0.identifier }
            let observations = selected.prefix(NativePushJournal.maxMatchedRequests).map { request in
                let snapshot = descriptor(request)
                return NativePushJournal.Context(eventId: snapshot?["eventId"],
                                                 accountId: snapshot?["clientName"], requestId: request.identifier)
            }
            for context in observations {
                NativePushJournal.shared?.enqueue(.deliveredObserved, context: context)
                NativePushJournal.shared?.enqueue(.removalRequested, context: context)
            }
            removeRequests(ids)
            listRequests { remaining in
                let present = Set(remaining.map { $0.identifier })
                let absent = ids.filter { !present.contains($0) }
                for context in observations {
                    if let id = context.requestId, !present.contains(id) {
                        NativePushJournal.shared?.enqueue(.removalObservedAbsent, context: context)
                    }
                }
                done(absent)
            }
        }
    }
}
