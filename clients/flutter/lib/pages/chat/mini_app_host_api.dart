import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/bot_interactive_picker.dart';
import 'package:liza/widgets/liza_app.dart';
import 'package:liza/pages/chat/mini_app_interactive.dart';

abstract class MiniAppHostApi {
  Future<String> fetchInitData();
  Future<void> sendData(Map<String, Object?> content);
  Future<String> createInviteLink(String? startPath);
}

/// Доверенный Dart↔Dart интерфейс. contactPhones никогда не возвращается в JS.
abstract class MiniAppInteractiveHostApi {
  Future<Map<String, dynamic>> interactiveRequest(
    String action,
    Map<String, dynamic> data,
  );
}

class RoomMiniAppHostApi implements MiniAppHostApi, MiniAppInteractiveHostApi {
  @visibleForTesting
  static http.Client Function() transportFactory = http.Client.new;
  final Room room;
  final String appId;
  final String appUrl;
  final String startParam;
  final String? botMxid;
  final String? joinRequestQueryId;
  final String interactiveSessionId;
  final MiniAppInteractiveState interactiveState;
  final bool Function()? isCurrent;
  final bool Function()? isInteractiveCurrent;
  final Future<void> Function()? beforePresent;
  final String? _accessToken;
  final String? _userId;
  final Uri? _homeserver;

  RoomMiniAppHostApi({
    required this.room,
    required this.appId,
    required this.appUrl,
    this.startParam = '',
    this.botMxid,
    this.joinRequestQueryId,
    this.interactiveSessionId = '',
    MiniAppInteractiveState? interactiveState,
    this.isCurrent,
    this.isInteractiveCurrent,
    this.beforePresent,
  }) : _accessToken = room.client.accessToken,
       _userId = room.client.userID,
       _homeserver = room.client.homeserver,
       interactiveState = interactiveState ?? MiniAppInteractiveState();

  bool get _current =>
      _accessToken != null &&
      interactiveState.active &&
      room.client.accessToken == _accessToken &&
      room.client.userID == _userId &&
      room.client.homeserver == _homeserver &&
      (isCurrent?.call() ?? true);

  Future<RegisteredBot?> _trustedBot(BotInteractiveApi api) async {
    final peer = botMxid ?? room.directChatMatrixID;
    if (!_current || peer == null) return null;
    final bot = await api.resolve(mxid: peer, force: true);
    if (!_current || bot?.appForUrl(appUrl)?.appId != appId) return null;
    return bot;
  }

  Future<void> _cancelQuery() async {
    final id = interactiveState.queryId;
    interactiveState.queryId = null;
    if (id == null) return;
    final api = BotInteractiveApi(room.client);
    try {
      // На сменившийся аккаунт запрос со старым ID вообще не посылаем.
      if (room.client.accessToken != _accessToken ||
          room.client.userID != _userId) {
        return;
      }
      await api.request(
        'POST',
        '/liza/interactive/query/$id/cancel',
        body: {'session_id': interactiveSessionId},
      );
    } catch (e) {
      Logs().w('[MiniAppHost] query cancellation failed: ${e.runtimeType}');
    } finally {
      api.dispose();
    }
  }

  Future<String?> _ensureQuery() async {
    if (interactiveSessionId.isEmpty || joinRequestQueryId != null) return null;
    final state = interactiveState;
    if (state.queryId != null &&
        state.queryExpiresAt > DateTime.now().millisecondsSinceEpoch ~/ 1000) {
      return state.queryId;
    }
    if (state.creatingQuery != null) return state.creatingQuery;
    Future<String?> create() async {
      final api = BotInteractiveApi(room.client);
      try {
        final bot = await _trustedBot(api);
        if (bot == null) return null;
        final result = await api.request(
          'POST',
          '/liza/interactive/query',
          body: {
            'kind': 'web_app',
            'bot_mxid': bot.mxid,
            'room_id': room.id,
            'session_id': interactiveSessionId,
            'app_id': appId,
          },
        );
        final id = result['query_id'];
        final expires = result['expires_at'];
        if (id is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(id) ||
            expires is! num) {
          throw const FormatException('Invalid query response');
        }
        state.queryId = id;
        state.queryExpiresAt = expires.toInt();
        state.cancelQuery = _cancelQuery;
        if (!_current) {
          await _cancelQuery();
          throw StateError('Mini App session changed');
        }
        return id;
      } finally {
        api.dispose();
      }
    }

    state.creatingQuery = create();
    try {
      return await state.creatingQuery;
    } finally {
      state.creatingQuery = null;
    }
  }

  @override
  Future<Map<String, dynamic>> interactiveRequest(
    String action,
    Map<String, dynamic> data,
  ) async {
    if (!_current) throw StateError('Mini App session changed');
    final doc = data['document_id'];
    if (action == 'activateDocument') {
      if (!interactiveState.authenticated ||
          doc is! String ||
          !RegExp(r'^[a-f0-9]{48}$').hasMatch(doc)) {
        throw StateError('Unauthenticated document');
      }
      interactiveState.documentId = doc;
      interactiveState.cancelledRequests.clear();
      interactiveState.requestEpochs.clear();
      return {'status': 'active'};
    }
    if (doc is! String ||
        doc != interactiveState.documentId ||
        !interactiveState.authenticated) {
      throw StateError('Mini App document changed');
    }
    final requestId = data['request_id'];
    if (action == 'cancelRequest') {
      if (requestId is String &&
          interactiveState.cancelledRequests.length < 512) {
        interactiveState.cancelledRequests.add(requestId);
      }
      return {'status': 'cancelled'};
    }
    if (requestId is String &&
        !interactiveState.requestEpochs.containsKey(requestId) &&
        interactiveState.requestEpochs.length >= 512) {
      throw StateError('Too many Mini App requests');
    }
    if (action == 'cancelDocument') {
      interactiveState.documentId = null;
      await _cancelQuery();
      return {'status': 'cancelled'};
    }
    final epoch = requestId is String
        ? interactiveState.requestEpochs.putIfAbsent(
            requestId,
            () => interactiveState.visibilityEpoch,
          )
        : interactiveState.visibilityEpoch;
    bool current() =>
        _current &&
        interactiveState.visible &&
        (isInteractiveCurrent?.call() ?? true) &&
        epoch == interactiveState.visibilityEpoch &&
        interactiveState.documentId == doc &&
        (requestId is! String ||
            !interactiveState.cancelledRequests.contains(requestId));
    if (!current()) throw StateError('Mini App request cancelled');
    if (action == 'check') return {'status': 'active'};
    final api = BotInteractiveApi(room.client);
    try {
      final bot = await _trustedBot(api);
      if (bot == null || !current()) return {'status': 'unavailable'};
      if (action == 'contactPhones' || action == 'confirmContact') {
        final entries = await room.client.getAccount3PIDs();
        if (!current()) throw StateError('Mini App session changed');
        final phones = [
          for (final entry in entries ?? <ThirdPartyIdentifier>[])
            if (entry.medium == ThirdPartyIdentifierMedium.msisdn)
              entry.address,
        ];
        if (action == 'contactPhones') {
          return {
            'phones': phones,
            'first_name': _userId?.localpart ?? '',
            'recipient': appUrl,
          };
        }
        final phone = data['phone_number'];
        if (phone is! String || !phones.contains(phone)) {
          return {'status': 'unavailable'};
        }
        return {
          'status': 'granted',
          'phone_number': phone,
          'first_name': _userId?.localpart ?? '',
        };
      }
      if (action == 'queryResult') {
        final id = interactiveState.queryId;
        if (id == null) return {'status': 'unavailable'};
        final result = await api.request(
          'GET',
          '/liza/interactive/query/$id',
          query: {'session_id': interactiveSessionId},
        );
        if (!current()) throw StateError('Mini App document changed');
        if (result['status'] != 'answered') return {'status': result['status']};
      } else if (action != 'prepared') {
        throw UnsupportedError(action);
      }
      if (interactiveState.presenting) return {'status': 'busy'};
      interactiveState.beginPresentation();
      try {
        await beforePresent?.call();
        final context = LizaApp
            .router
            .routerDelegate
            .navigatorKey
            .currentState
            ?.overlay
            ?.context;
        if (context == null || !context.mounted || !current()) {
          return {'status': 'unavailable'};
        }
        bool sent;
        if (action == 'prepared') {
          final id = data['id'];
          if (id is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(id)) {
            throw const FormatException('Invalid prepared id');
          }
          sent = await handlePreparedBotRequest(
            context: context,
            client: room.client,
            room: room,
            preparedId: id,
            expectedBotMxid: bot.mxid,
            appId: appId,
            sessionId: interactiveSessionId,
            isCurrent: current,
          );
        } else {
          sent = await handleBotQueryResult(
            context: context,
            client: room.client,
            room: room,
            queryId: interactiveState.queryId!,
            sessionId: interactiveSessionId,
            isCurrent: current,
          );
          if (!sent) await _cancelQuery();
        }
        return {'status': sent && current() ? 'sent' : 'cancelled'};
      } finally {
        interactiveState.presenting = false;
      }
    } finally {
      api.dispose();
    }
  }

  @override
  Future<String> fetchInitData() async {
    if (!_current) throw StateError('Mini App session changed');
    interactiveState.authenticated = false;
    final queryId = await _ensureQuery();
    if (!_current) throw StateError('Mini App session changed');
    final transport = transportFactory();
    try {
      final request =
          http.Request(
              'POST',
              _homeserver!.resolve('/_synapse/client/miniapp/v1/init_data'),
            )
            ..followRedirects = false
            ..headers.addAll({
              'Authorization': 'Bearer $_accessToken',
              'Content-Type': 'application/json',
            })
            ..body = jsonEncode({
              'app_id': appId,
              'app_url': appUrl,
              'room_id': room.id,
              if (startParam.isNotEmpty) 'start_param': startParam,
              if (joinRequestQueryId != null)
                'chat_join_request_query_id': joinRequestQueryId,
              if (queryId != null) 'query_id': queryId,
            });
      final response = await http.Response.fromStream(
        await transport.send(request).timeout(const Duration(seconds: 15)),
      ).timeout(const Duration(seconds: 15));
      if (!_current) throw StateError('Mini App session changed');
      if (response.statusCode != 200) {
        throw StateError('init_data: ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['verified_app_url'] != appUrl ||
          Uri.tryParse(appUrl)?.scheme != 'https') {
        throw StateError('Unverified Mini App URL');
      }
      final value = data['init_data'];
      if (value is! String || value.isEmpty) {
        throw const FormatException('Empty init_data');
      }
      interactiveState.authenticated = true;
      return value;
    } finally {
      transport.close();
    }
  }

  @override
  Future<void> sendData(Map<String, Object?> content) async {
    if (!_current) throw StateError('Mini App session changed');
    await room.sendEvent(content);
  }

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
