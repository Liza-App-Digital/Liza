import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:liza/utils/update_policy.dart';

/// Нижний рубеж режима чтения обязательного обновления.
///
/// Экран чата отбивает действия сам (с подсказкой), но писать в комнату умеют
/// десятки мест: стикеры, кнопки ботов, обсуждения каналов, мини-аппы, сторис.
/// Здесь отказ получают ВСЕ отправки событий в комнату, какой бы экран их ни
/// начал: ответ собирается локально, в сеть запрос не уходит. SDK разбирает его
/// как обычную `MatrixException` и оставляет событие в очереди со статусом
/// ошибки — после обновления его можно повторить.
///
/// Не трогаем: квитанции, typing, to-device и ключи E2EE, state-события,
/// загрузку медиа и события звонков `m.call.*` (принять входящий звонок можно).
class UpdateReadOnlyHttpClient extends http.BaseClient {
  UpdateReadOnlyHttpClient(this._inner, {bool Function()? readOnly})
    : _readOnly = readOnly ?? (() => UpdatePolicyController.readOnly);

  final http.Client _inner;
  final bool Function() _readOnly;

  static const errcode = 'LIZA_UPDATE_REQUIRED';

  /// Идёт ли звонок. В зашифрованной комнате сигналинг звонка уходит как
  /// `m.room.encrypted` и по URL неотличим от сообщения — пока разговор идёт,
  /// шифрованные события пропускаем, иначе нельзя ни ответить, ни положить
  /// трубку. Ставит `MatrixState`.
  static bool Function() isCallActive = _noCall;

  static bool _noCall() => false;

  static final _roomWrite = RegExp(
    r'^/_matrix/client/[^/]+/rooms/[^/]+/(send|redact)/([^/]+)',
  );

  static bool isBlockedRoomWrite(http.BaseRequest request) {
    if (request.method != 'PUT') return false;
    final match = _roomWrite.firstMatch(request.url.path);
    if (match == null) return false;
    if (match.group(1) == 'redact') return true;
    final type = Uri.decodeComponent(match.group(2)!);
    if (type.startsWith('m.call.')) return false;
    if (type == 'm.room.encrypted' && isCallActive()) return false;
    return true;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_readOnly() && isBlockedRoomWrite(request)) {
      final body = utf8.encode(
        jsonEncode({
          'errcode': errcode,
          'error': 'Update the app to send messages',
        }),
      );
      return http.StreamedResponse(
        Stream.value(body),
        400,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
