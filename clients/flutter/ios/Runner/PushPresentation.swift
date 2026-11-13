import Foundation

/// Решение `AppDelegate.willPresent` для пуша на переднем плане — без UIKit,
/// чтобы проверять его host-тестом (`test/native/push_presentation_test.dart`).
enum PushPresentation: Equatable {
    /// Не показывать ничего.
    case suppress
    /// Показать баннер со звуком (удалённый пуш, нарисованный NSE).
    case show
    /// Локальное уведомление flutter_local_notifications — решает плагин.
    case plugin

    static func decide(
        userInfo: [AnyHashable: Any],
        isRemote: Bool,
        appActive: Bool,
        inActiveRoom: Bool
    ) -> PushPresentation {
        guard isRemote else { return .plugin }
        // Пуш снятия v2 (этап 3): на переднем плане чистит сам Dart по sync —
        // запасной текст «Новые сообщения прочитаны» здесь не нужен.
        if (userInfo["liza_clear"] as? NSNumber)?.intValue == 2 { return .suppress }
        guard userInfo["room_id"] != nil else { return .plugin }
        // Чат уже открыт на экране — сообщение и так видно, баннер со звуком лишний
        // (жалоба 2026-09-15 «пришёл пуш о сообщении в активном чате»).
        if appActive && inActiveRoom { return .suppress }
        return .show
    }
}
