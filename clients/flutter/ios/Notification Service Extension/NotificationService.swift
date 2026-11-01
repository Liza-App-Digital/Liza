//
//  NotificationService.swift
//  Notification Extension
//
//  Created by Christian Pauly on 26.08.25.
//

import UserNotifications
import Intents
import os

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    var diagnosticJournal: NativePushJournal? = NativePushJournal.shared

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let eventId = request.content.userInfo["event_id"] as? String
        let journal = diagnosticJournal
        journal?.append(.nseReceived, eventId: eventId)
        // Обёртка наблюдает прежние вызовы, не меняет payload/число callback.
        let originalHandler = contentHandler
        let contentHandler: (UNNotificationContent) -> Void = { content in
            journal?.append(.nseCompleted, eventId: eventId)
            originalHandler(content)
        }
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        if let bestAttemptContent = bestAttemptContent {
            os_log("[LizaPushHelper] New message received")

            guard let roomId = bestAttemptContent.userInfo["room_id"] as? String,
                  let _ = bestAttemptContent.userInfo["event_id"] as? String else {
                os_log("[LizaPushHelper] Room ID or Event ID is missing!")
                journal?.append(.nseError, eventId: eventId)
                let emptyContent = UNMutableNotificationContent()
                contentHandler(emptyContent)
                return
            }
            bestAttemptContent.threadIdentifier = roomId

            // Extract sender, room name, and content from the push payload.
            // Sygnal puts these into userInfo fields and/or aps.alert.loc-args.
            let senderName = bestAttemptContent.userInfo["sender_display_name"] as? String
            let roomName = bestAttemptContent.userInfo["room_name"] as? String
            let eventType = bestAttemptContent.userInfo["type"] as? String
            let senderId = bestAttemptContent.userInfo["sender"] as? String

            // Try to get message content from the nested "content" dict.
            // LABA-2238: у медиа сервер шлёт `body` ТОЛЬКО если это реальная
            // подпись; для медиа-фолбэка (body == имя файла) body отсутствует, а
            // тип берём из `msgtype` (+ `voice`-флаг).
            var messageBody: String? = nil
            var msgtype: String? = nil
            var isVoice = false
            if let contentDict = bestAttemptContent.userInfo["content"] as? [String: Any] {
                messageBody = contentDict["body"] as? String
                msgtype = contentDict["msgtype"] as? String
                isVoice = (contentDict["voice"] as? Bool) ?? false
            }
            // If content is a JSON string, try parsing it
            if msgtype == nil, let contentString = bestAttemptContent.userInfo["content"] as? String,
               let contentData = contentString.data(using: .utf8),
               let contentDict = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] {
                messageBody = contentDict["body"] as? String
                msgtype = contentDict["msgtype"] as? String
                isVoice = (contentDict["voice"] as? Bool) ?? false
            }

            // Determine if this is an encrypted message
            let isEncrypted = eventType == "m.room.encrypted"

            // LABA-2238: медиа без подписи → строка-по-типу вместо имени файла.
            if !isEncrypted, messageBody == nil,
               let label = Self.mediaTypeLabel(msgtype, isVoice: isVoice) {
                messageBody = label
            }

            let fallbackBody = String(
                localized: "New message - open app to read",
                comment: "Default notification body"
            )

            // Determine if this is a group chat (has room_name → group, otherwise DM)
            let isGroupChat = roomName != nil && !roomName!.isEmpty

            // Build title and body
            if let sender = senderName {
                if isGroupChat {
                    // Group chat: title = room name
                    bestAttemptContent.title = roomName!
                    if let body = messageBody, !isEncrypted {
                        bestAttemptContent.body = "\(sender): \(body)"
                    } else {
                        bestAttemptContent.body = String(
                            localized: "\(sender) sent a message",
                            comment: "Encrypted message notification body. Variable is the sender name."
                        )
                    }
                } else {
                    // Direct chat: title = sender name
                    bestAttemptContent.title = sender
                    if let body = messageBody, !isEncrypted {
                        bestAttemptContent.body = body
                    } else {
                        bestAttemptContent.body = String(
                            localized: "\(sender) sent a message",
                            comment: "Encrypted message notification body. Variable is the sender name."
                        )
                    }
                }
            } else {
                // Fallback: no sender info available
                bestAttemptContent.title = roomName ?? fallbackBody
                bestAttemptContent.body = fallbackBody
            }

            // Set sound and interruption level.
            // UNNotificationSound(named:) looks for the file in the app/extension bundle.
            bestAttemptContent.sound = UNNotificationSound(named: UNNotificationSoundName("liza_ding.aiff"))
            if #available(iOSApplicationExtension 15.0, macOSApplicationExtension 12.0, *) {
                bestAttemptContent.interruptionLevel = .timeSensitive
            }

            // Бейдж — из КЛИЕНТ-авторитетного числа в App Group (его пишет Dart
            // на каждый sync), а НЕ из сырого серверного counts.unread: последнее
            // считает topology-скрытые (stories) и server-stuck (федеративные)
            // комнаты, которые клиент исключает → накопительная инфляция бейджа.
            // Ставим РОВНО сохранённое число (без инкремента: несколько пушей при
            // закрытом приложении читают один снимок → инкремент дал бы двойной
            // счёт). Пусто (холодный первый пуш до sync) или 0 при alert-пуше → 1
            // (нижняя граница «есть непрочитанное»; NSE всегда alert-путь).
            // См. RL-app-badge-native-visible-count.
            let badgeDefaults = UserDefaults(suiteName: appGroup())
            let savedBadge = badgeDefaults?.object(forKey: "badge_count") as? Int
            bestAttemptContent.badge = NSNumber(
                value: (savedBadge ?? 0) > 0 ? savedBadge! : 1
            )

            // Attempt to download sender avatar and attach as Communication Notification.
            fetchAvatar(senderId: senderId) { [weak self] attachmentUrl in
                guard let self = self else {
                    contentHandler(bestAttemptContent)
                    return
                }

                if #available(iOSApplicationExtension 15.0, macOSApplicationExtension 12.0, *) {
                    // iOS 15+: показываем аватар слева через Communication Notification (как Liza).
                    // Attachment справа не ставим — иначе аватар дублируется.
                    let finalContent = self.applyCommunicationNotification(
                        content: bestAttemptContent,
                        senderName: senderName,
                        senderId: senderId,
                        roomName: roomName,
                        isGroupChat: isGroupChat,
                        avatarUrl: attachmentUrl
                    )
                    contentHandler(finalContent)
                } else {
                    // iOS <15: Communication Notification недоступен,
                    // показываем аватар справа через стандартный attachment.
                    if let url = attachmentUrl {
                        do {
                            let attachment = try UNNotificationAttachment(
                                identifier: "avatar",
                                url: url,
                                options: [UNNotificationAttachmentOptionsThumbnailHiddenKey: false]
                            )
                            bestAttemptContent.attachments = [attachment]
                        } catch {
                            os_log("[LizaPushHelper] Failed to create avatar attachment: %{public}@", error.localizedDescription)
                        }
                    }
                    contentHandler(bestAttemptContent)
                }
                self.contentHandler = nil
            }
        }
    }

    /// LABA-2238: локализованная строка-по-типу для медиа-сообщения без подписи.
    /// Сервер (Sygnal) НЕ шлёт `body`, если это имя файла — иначе в баннере
    /// светился бы `recording…ogg` вместо «🎤 Голосовое сообщение».
    static func mediaTypeLabel(_ msgtype: String?, isVoice: Bool) -> String? {
        switch msgtype {
        case "m.image":
            return String(localized: "🖼 Фото", comment: "Push banner: image message")
        case "m.video":
            return String(localized: "🎬 Видео", comment: "Push banner: video message")
        case "m.file":
            return String(localized: "📎 Файл", comment: "Push banner: file message")
        case "m.sticker":
            return String(localized: "Стикер", comment: "Push banner: sticker message")
        case "m.audio":
            return isVoice
                ? String(localized: "🎤 Голосовое сообщение", comment: "Push banner: voice message")
                : String(localized: "🎤 Аудио", comment: "Push banner: audio message")
        default:
            return nil
        }
    }

    override func serviceExtensionTimeWillExpire() {
        diagnosticJournal?.append(.nseExpired, eventId: bestAttemptContent?.userInfo["event_id"] as? String)
        // Deliver whatever we have so far (possibly without avatar).
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - Communication Notification (iOS 15+)

    /// Wraps the notification content with INSendMessageIntent so the avatar
    /// appears on the LEFT side (like Liza), not just as a right-side attachment.
    @available(iOSApplicationExtension 15.0, macOSApplicationExtension 12.0, *)
    private func applyCommunicationNotification(
        content: UNMutableNotificationContent,
        senderName: String?,
        senderId: String?,
        roomName: String?,
        isGroupChat: Bool,
        avatarUrl: URL?
    ) -> UNNotificationContent {
        let senderHandle = INPersonHandle(
            value: senderId ?? "unknown",
            type: .unknown
        )

        // Load avatar image for the person
        var avatarImage: INImage? = nil
        if let url = avatarUrl, let data = try? Data(contentsOf: url) {
            avatarImage = INImage(imageData: data)
        }

        let sender = INPerson(
            personHandle: senderHandle,
            nameComponents: nil,
            displayName: senderName ?? "Unknown",
            image: avatarImage,
            contactIdentifier: nil,
            customIdentifier: senderId
        )

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: isGroupChat ? INSpeakableString(spokenPhrase: roomName ?? "") : nil,
            conversationIdentifier: content.threadIdentifier,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )

        // Note: we don't set a group avatar here because the push payload only
        // contains the sender's avatar, not the room avatar. Setting the sender's
        // avatar as the group image would be misleading.

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { error in
            if let error = error {
                os_log("[LizaPushHelper] INInteraction donate failed: %{public}@", error.localizedDescription)
            }
        }

        do {
            let updatedContent = try content.updating(from: intent)
            // content.updating(from:) returns a new UNNotificationContent that may
            // discard the custom sound we set earlier. Re-apply sound and
            // interruptionLevel on the mutable copy so the notification plays audio.
            if let mutable = updatedContent.mutableCopy() as? UNMutableNotificationContent {
                mutable.sound = content.sound ?? UNNotificationSound(named: UNNotificationSoundName("liza_ding.aiff"))
                if #available(iOSApplicationExtension 15.0, macOSApplicationExtension 12.0, *) {
                    mutable.interruptionLevel = content.interruptionLevel
                }
                return mutable
            }
            return updatedContent
        } catch {
            os_log("[LizaPushHelper] Failed to apply communication notification: %{public}@", error.localizedDescription)
            return content
        }
    }

    // MARK: - Avatar fetching

    /// App Group, вычисленная из bundle id расширения.
    ///
    /// Дублирует lizaAppGroup() из ApnsPushPlugin.swift намеренно: тот файл
    /// не входит в таргет расширения, а тащить общий файл в два таргета ради
    /// четырёх строк — избыточно. При правке синхронизировать оба места.
    private func appGroup() -> String {
        guard let bundleId = Bundle.main.bundleIdentifier else { return "" }
        let appId = bundleId.split(separator: ".").dropLast().joined(separator: ".")
        return "group.\(appId)"
    }

    /// Downloads the sender's avatar from the Matrix homeserver via the shared
    /// App Group credentials. Two HTTP requests: profile lookup + thumbnail download.
    /// Returns a local file URL for the avatar image, or nil on failure.
    private func fetchAvatar(senderId: String?, completion: @escaping (URL?) -> Void) {
        let defaults = UserDefaults(suiteName: appGroup())
        guard let homeserver = defaults?.string(forKey: "homeserverUrl"),
              let accessToken = defaults?.string(forKey: "accessToken"),
              let sender = senderId,
              !sender.isEmpty else {
            completion(nil)
            return
        }

        // Step 1: GET /_matrix/client/v3/profile/{userId}/avatar_url
        let encodedSender = sender.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sender
        guard let profileUrl = URL(string: "\(homeserver)/_matrix/client/v3/profile/\(encodedSender)/avatar_url") else {
            completion(nil)
            return
        }

        var profileRequest = URLRequest(url: profileUrl)
        profileRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        profileRequest.timeoutInterval = 5

        URLSession.shared.dataTask(with: profileRequest) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mxcUrl = json["avatar_url"] as? String,
                  mxcUrl.hasPrefix("mxc://") else {
                os_log("[LizaPushHelper] Avatar profile lookup failed or no avatar")
                completion(nil)
                return
            }

            // Step 2: Convert mxc:// to authenticated thumbnail URL
            let mxcParts = String(mxcUrl.dropFirst(6)) // remove "mxc://"
            let parts = mxcParts.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else {
                completion(nil)
                return
            }
            let server = String(parts[0])
            let mediaId = String(parts[1])

            guard let thumbnailUrl = URL(string: "\(homeserver)/_matrix/client/v1/media/thumbnail/\(server)/\(mediaId)?width=64&height=64&method=crop") else {
                completion(nil)
                return
            }

            var thumbRequest = URLRequest(url: thumbnailUrl)
            thumbRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            thumbRequest.timeoutInterval = 5

            URLSession.shared.dataTask(with: thumbRequest) { imgData, _, error in
                guard let imgData = imgData, error == nil, !imgData.isEmpty else {
                    os_log("[LizaPushHelper] Avatar thumbnail download failed")
                    completion(nil)
                    return
                }

                // Step 3: Save to temp file for UNNotificationAttachment
                let tmpUrl = FileManager.default.temporaryDirectory
                    .appendingPathComponent("avatar_\(mediaId).jpg")
                do {
                    try imgData.write(to: tmpUrl)
                    completion(tmpUrl)
                } catch {
                    os_log("[LizaPushHelper] Failed to write avatar to temp file: %{public}@", error.localizedDescription)
                    completion(nil)
                }
            }.resume()
        }.resume()
    }
}
