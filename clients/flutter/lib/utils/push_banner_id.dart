import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Р3 (спека 2026-11-12-push-sync-industry-alignment): один ID баннера события
/// на всех путях macOS. Sygnal ставит его в `apns-collapse-id`
/// (`collapse_id_for_event` в `apnspushkin.py`, флаг `collapse_by_event`), а
/// система делает collapse-id идентификатором запроса. Локальный баннер с тем
/// же ID опоздавший APNs ЗАМЕНЯЕТ, а не дублирует. Формулу менять только
/// вместе с Sygnal — страж сверяет обе по одному вектору.
String pushBannerId(String clientName, String eventId) {
  final digest = sha256.convert(utf8.encode('$clientName|$eventId'));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// Показывать ли локальный баннер macOS нативно под [pushBannerId].
/// Выключено, пока опыт Ф1.0 (`pushes.md` §27) не покажет, что замена по
/// collapse-id не звучит повторно, и пока у Sygnal не включён
/// `collapse_by_event`. Включить для пробы: `--dart-define=LIZA_MACOS_UNIFIED_BANNER=true`.
const macosUnifiedBannerId = bool.fromEnvironment(
  'LIZA_MACOS_UNIFIED_BANNER',
  defaultValue: false,
);
