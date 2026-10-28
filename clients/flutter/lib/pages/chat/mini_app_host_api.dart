import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/miniapp_room.dart';

/// Всё, что контенту mini App нужно от Matrix-аккаунта.
///
/// Контент живёт либо в окне Лизы (панель), либо в отдельном окне ОС со своим
/// Flutter-движком — там нет ни Client, ни Room, ни ключей E2EE. Поэтому
/// контент ходит к аккаунту только через этот интерфейс: в окне Лизы —
/// [RoomMiniAppHostApi] напрямую, в отдельном окне — RPC к главному движку
/// (`mini_app_window.dart`), который отвечает тем же [RoomMiniAppHostApi].
abstract class MiniAppHostApi {
  /// Подписанная Synapse initData (`/_synapse/client/miniapp/v1/init_data`).
  Future<String> fetchInitData();

  /// Отправляет `com.liza.miniapp.data` в комнату (комната может быть
  /// зашифрована — шифрует только Client главного движка).
  Future<void> sendData(Map<String, Object?> content);

  /// Invite-ссылка на комнату-лаунчер mini App с deep-link [startPath].
  Future<String> createInviteLink(String? startPath);
}

class RoomMiniAppHostApi implements MiniAppHostApi {
  final Room room;
  final String appId;
  final String appUrl;

  RoomMiniAppHostApi({
    required this.room,
    required this.appId,
    required this.appUrl,
  });

  @override
  Future<String> fetchInitData() async {
    final client = room.client;
    final response = await http.post(
      client.homeserver!.resolve('/_synapse/client/miniapp/v1/init_data'),
      headers: {
        'Authorization': 'Bearer ${client.accessToken}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'app_id': appId, 'room_id': room.id}),
    );
    if (response.statusCode != 200) {
      throw Exception('init_data: ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['init_data'] as String;
  }

  @override
  Future<void> sendData(Map<String, Object?> content) =>
      room.sendEvent(content);

  @override
  Future<String> createInviteLink(String? startPath) async {
    final client = room.client;
    final token = client.accessToken;
    if (token == null) throw StateError('нет access token');

    // Ссылку создаём на комнату-ЛАУНЧЕР (с com.liza.miniapp.config): redeem и
    // лендинг детектят mini App именно по этому state-event. room может
    // быть DM с launch-карточкой (например чат с «Лизой»), где конфига нет — по
    // такой ссылке mini App не распознаётся. Если у room конфига нет —
    // ищем комнату-лаунчер этого приложения среди комнат пользователя.
    var linkRoom = room;
    if (miniAppLaunchForRoom(room) == null) {
      for (final r in client.rooms) {
        final launch = miniAppLaunchForRoom(r);
        if (launch != null &&
            (launch.appId == appId || launch.appUrl == appUrl)) {
          linkRoom = r;
          break;
        }
      }
    }
    // server_name — домен из room.id (как в cross-HS фиксе инвайт-ссылок).
    final serverName = linkRoom.id.split(':').last;

    final info = await AuthProxyService().createInvite(
      serverName: serverName,
      roomId: linkRoom.id,
      accessToken: token,
      appStartPath: startPath,
    );
    return info.url;
  }
}
