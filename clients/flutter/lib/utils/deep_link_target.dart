import 'package:matrix/matrix.dart';

import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/miniapp_invite_redeem.dart';
import 'package:liza/utils/wait_for_room_in_sync.dart';

/// Тип цели, на которую ведёт короткая ссылка `me.liza.ru`.
enum DeepLinkKind { invite, story, channel, user, bot }

/// Результат резолва ссылки — куда именно вести пользователя.
///
/// Зачем отдельный тип: резолв зовут ДВА независимых пути (роутер, когда юзер
/// уже залогинен, и post-login хелпер, когда он логинился ради ссылки). Раньше
/// у каждого была своя копия логики, и они разошлись: post-login не ждал
/// комнату в sync и не различал пространство — отсюда пустой экран и
/// «просто список чатов». Общий тип + общий резолвер делают расхождение
/// невозможным по конструкции.
sealed class DeepLinkTarget {
  const DeepLinkTarget();
}

/// Обычная комната (чат/канал) — открыть ChatPage.
class DeepLinkRoom extends DeepLinkTarget {
  const DeepLinkRoom(this.roomId);
  final String roomId;
}

/// Пространство — открыть список пространства, а НЕ ChatPage.
class DeepLinkSpace extends DeepLinkTarget {
  const DeepLinkSpace(this.roomId);
  final String roomId;
}

class DeepLinkJoinRequest extends DeepLinkTarget {
  const DeepLinkJoinRequest(this.roomId);
  final String roomId;
}

/// Сторис: вьюер пушится императивно, поэтому маршрут — нейтральный.
class DeepLinkStory extends DeepLinkTarget {
  const DeepLinkStory(this.roomId, this.eventId);
  final String roomId;
  final String eventId;
}

/// Mini App: открыт поверх UI либо есть DM-комната приложения.
class DeepLinkMiniApp extends DeepLinkTarget {
  const DeepLinkMiniApp({this.dmRoomId, required this.opened});
  final String? dmRoomId;
  final bool opened;
}

/// Пользователь (user-invite «Пригласить друзей»): маршрут нейтральный, а
/// карточка профиля открывается побочным эффектом поверх списка чатов — тем
/// же кодом, что и ссылка `/u/<ник>`. Раньше здесь сразу делался
/// `startDirectChat`: для своей ссылки Synapse отвечал 403 → «список чатов»
/// (LABA-2551), для чужой — DM и invite собеседнику создавались ДО первого
/// сообщения (инвариант черновика, [[RL-direct-chat-draft-on-first-send]]).
class DeepLinkUser extends DeepLinkTarget {
  const DeepLinkUser(this.userId);
  final String userId;
}

/// Ссылка валидна, но конкретной цели нет (аномалия бэка, комната не доехала).
/// Не ошибка: ведём в список чатов, а не на экран «битого приглашения».
class DeepLinkNeutral extends DeepLinkTarget {
  const DeepLinkNeutral();
}

/// Ссылка нерабочая: несёт готовый путь экрана ошибки.
class DeepLinkFailure extends DeepLinkTarget {
  const DeepLinkFailure(this.routePath);
  final String routePath;
}

/// Путь роутера для цели.
String deepLinkRoutePath(DeepLinkTarget target) => switch (target) {
  DeepLinkJoinRequest(:final roomId) => Uri(
    path: '/join-request',
    queryParameters: {'room_id': roomId},
  ).toString(),
  DeepLinkRoom(:final roomId) => '/rooms/${Uri.encodeComponent(roomId)}',
  DeepLinkSpace(:final roomId) =>
    '/rooms?spaceId=${Uri.encodeComponent(roomId)}',
  DeepLinkStory() => '/rooms',
  DeepLinkMiniApp(:final dmRoomId, :final opened) =>
    (opened || dmRoomId == null || dmRoomId.isEmpty)
        ? '/rooms'
        : '/rooms/${Uri.encodeComponent(dmRoomId)}',
  DeepLinkUser() => '/rooms',
  DeepLinkNeutral() => '/rooms',
  DeepLinkFailure(:final routePath) => routePath,
};

/// Побочный эффект, который нужно выполнить ПОСЛЕ навигации на
/// [deepLinkRoutePath] — там, где есть BuildContext (роутер).
sealed class DeepLinkSideEffect {
  const DeepLinkSideEffect();
}

/// Открыть карточку профиля пользователя поверх текущего экрана.
class OpenUserProfile extends DeepLinkSideEffect {
  const OpenUserProfile(this.userId);
  final String userId;
}

/// Чистая пара к [deepLinkRoutePath]: путь не несёт информации о цели, поэтому
/// побочный эффект вычисляется отдельным exhaustive switch — новый вариант
/// [DeepLinkTarget] без ветки здесь не скомпилируется, в отличие от
/// `if (target is …)` в месте вызова.
DeepLinkSideEffect? deepLinkSideEffect(DeepLinkTarget target) =>
    switch (target) {
      DeepLinkUser(:final userId) => OpenUserProfile(userId),
      DeepLinkRoom() ||
      DeepLinkJoinRequest() ||
      DeepLinkSpace() ||
      DeepLinkStory() ||
      DeepLinkMiniApp() ||
      DeepLinkNeutral() ||
      DeepLinkFailure() => null,
    };

/// Ждёт появления комнаты в sync. Вынесено в параметр, чтобы резолв можно было
/// тестировать без живого Client.
typedef AwaitRoom =
    Future<bool> Function(String roomId, {required bool expectSpace});

/// Возвращает isSpace комнаты, либо null если комнаты нет локально.
typedef LookupRoomIsSpace = bool? Function(String roomId);

/// Чистое ядро резолва: из ответа auth-proxy делает цель навигации.
///
/// Обе точки входа (роутер и post-login) обязаны ходить сюда — иначе снова
/// разъедутся, как было до объединения.
Future<DeepLinkTarget> resolveInviteTargetFromResult({
  required InviteRedeemResult result,
  required String code,
  required AwaitRoom awaitRoom,
  required LookupRoomIsSpace lookupRoomIsSpace,
}) async {
  switch (result.status) {
    case 'join_requested':
      final roomId = result.roomId;
      return roomId == null || roomId.isEmpty
          ? const DeepLinkNeutral()
          : DeepLinkJoinRequest(roomId);
    case 'user_invite':
      // Бэк для user-инвайта только резолвит цель (handler.py: «DM создаёт
      // клиент»). DM здесь НЕ создаём: чат рождается с первым сообщением из
      // карточки профиля (черновик), а своя ссылка иначе давала бы 403.
      final targetUserId = result.targetUserId;
      if (targetUserId == null || targetUserId.isEmpty) {
        Logs().w('[DeepLink] user_invite без target_user_id (code=$code)');
        return const DeepLinkNeutral();
      }
      return DeepLinkUser(targetUserId);
    case 'already_joined':
    case 'joined':
    case 'invited':
    case 'ok':
      final roomId = result.roomId;
      if (roomId == null || roomId.isEmpty) {
        Logs().w('[DeepLink] status=${result.status} без room_id (code=$code)');
        return const DeepLinkNeutral();
      }
      final expectSpace = result.targetKind == 'space';
      final arrived = await awaitRoom(roomId, expectSpace: expectSpace);
      if (!arrived) {
        Logs().w('[DeepLink] room $roomId не появился в sync (code=$code)');
        return const DeepLinkNeutral();
      }
      final isSpace = expectSpace || (lookupRoomIsSpace(roomId) ?? false);
      return isSpace ? DeepLinkSpace(roomId) : DeepLinkRoom(roomId);
    case 'needs_account_on_target_server':
      return DeepLinkFailure('/invite/$code/needs-account');
    default:
      Logs().w('[DeepLink] неизвестный статус redeem: ${result.status}');
      return DeepLinkFailure('/invite/$code/error');
  }
}

/// Полный резолв инвайт-кода: сетевой redeem + ожидание sync + ветка
/// mini-app, требующая живого клиента.
Future<DeepLinkTarget> resolveInviteTarget({
  required Client client,
  required AuthProxyService service,
  required String code,
}) async {
  final accessToken = client.accessToken ?? '';
  if (accessToken.isEmpty) {
    Logs().w('[DeepLink] нет access_token, инвайт отброшен');
    return const DeepLinkNeutral();
  }
  try {
    final result = await service.redeemInvite(
      code: code,
      accessToken: accessToken,
    );
    if (result.status == 'miniapp_invite') {
      final outcome = await handleMiniAppInviteRedeem(client, result);
      return DeepLinkMiniApp(
        dmRoomId: outcome.dmRoomId,
        opened: outcome.opened,
      );
    }
    return resolveInviteTargetFromResult(
      result: result,
      code: code,
      awaitRoom: (roomId, {required expectSpace}) => waitForRoomInSync(
        client,
        roomId,
        expectSpace: expectSpace,
        timeout: const Duration(seconds: 15),
      ),
      lookupRoomIsSpace: (roomId) => client.getRoomById(roomId)?.isSpace,
    );
  } on AuthProxyException catch (e) {
    return DeepLinkFailure(switch (e.statusCode) {
      404 => '/invite/$code/not-found',
      410 => '/invite/$code/expired',
      403 => '/invite/$code/room-gone',
      _ => '/invite/$code/error',
    });
  } catch (e) {
    Logs().e('[DeepLink] resolveInviteTarget failed: $e');
    return DeepLinkFailure('/invite/$code/error');
  }
}
