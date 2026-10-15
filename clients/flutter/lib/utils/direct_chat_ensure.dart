import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// In-flight вызовы `startDirectChat` per Client → mxid. Expando GC-ится вместе
/// с клиентом — централизованной точки «клиент удалён» в MatrixState нет.
final _inFlight = Expando<Map<String, Future<String>>>('ensureDirectChat');

/// Таймаут на ВЫДАВАЕМЫЙ вызывающему Future, не на операцию: SDK
/// `waitForRoomInSync` ждёт sync без таймаута, и при мёртвом sync
/// `showFutureLoadingDialog` (barrierDismissible:false) висел бы вечно.
/// Переменная — только ради стража (AC-9 не ждёт 30 с реального времени).
@visibleForTesting
Duration ensureDirectChatTimeout = const Duration(seconds: 30);

/// Единственная точка создания/получения личного чата в клиенте.
///
/// SDK пишет `m.direct` ТОЛЬКО ПОСЛЕ `createRoom` + waitForRoomInSync, а
/// `getDirectChatFromUserId` не видит свою свежесозданную join-комнату →
/// два параллельных `startDirectChat` (двойной клик на ПК) оба создают комнату
/// и собеседнику приходят ДВА приглашения (инцидент 2026-09-16, Windows).
/// Поэтому параллельные вызовы по одному mxid делят ОДИН underlying вызов.
///
/// Запись живёт до завершения underlying (успех/ошибка) и НЕ сбрасывается по
/// таймауту view: операцию отменить нельзя, а сброс открыл бы гонку заново на
/// границе таймаута. Повторный клик после таймаута снова ждёт ту же операцию.
///
/// Пре-чек существующего DM (m.direct / member-стейт / cross-HS скан) остаётся у
/// вызывающего — воронка семантику поиска не меняет. Прямой
/// `client.startDirectChat` в lib/** запрещён стражем
/// `RL-direct-chat-single-flight`.
///
/// [initialState] уходит в `createRoom` ТОЛЬКО новой комнаты (существующий DM
/// SDK возвращает как есть) и в ключ мемо не входит: параллельный вызов по тому
/// же mxid получит комнату первого («первый побеждает»). Единственный
/// вызывающий с state — `openSupportChat`, он сериализован своим гейтом.
///
/// [forceNew] — создать ЕЩЁ один DM, даже если с [mxid] уже есть (новый запрос к
/// Лизе, пересоздание её основного DM). Ключ мемо отдельный: иначе тап «Новый
/// запрос» во время фонового `_ensureLizaDm` получил бы основной DM, а не новый.
/// Двойной тап по-прежнему даёт одну комнату, последовательные вызовы — новые.
extension EnsureDirectChat on Client {
  Future<String> ensureDirectChat(
    String mxid, {
    List<StateEvent>? initialState,
    bool forceNew = false,
  }) {
    final map = _inFlight[this] ??= {};
    final key = forceNew ? '$mxid#new' : mxid;
    final pending = map[key] ??=
        startDirectChat(
          mxid,
          enableEncryption: false,
          initialState: initialState,
          skipExistingChat: forceNew,
        ).whenComplete(() {
          map.remove(key);
        });
    return pending.timeout(ensureDirectChatTimeout);
  }
}
