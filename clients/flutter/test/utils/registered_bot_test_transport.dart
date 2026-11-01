import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:liza/utils/bot_interactive_api.dart';

/// Тестовый реестр задаёт авторизацию явно; роль ai больше не даёт её сама.
void installRegisteredBotTestTransport() {
  BotInteractiveApi.transportFactory = () => MockClient((request) async {
    final mxid = request.url.queryParameters['mxid'] ?? '';
    return http.Response(
      jsonEncode({
        'registered':
            mxid.startsWith('@bot_father:') || mxid.startsWith('@bo_food:'),
        'mxid': mxid,
        'miniapps': <Object>[],
      }),
      200,
    );
  });
}

void resetRegisteredBotTestTransport() =>
    BotInteractiveApi.transportFactory = http.Client.new;
