import 'package:flutter/foundation.dart';
import 'package:smart_auth/smart_auth.dart';

/// Достаёт код из текста СМС: РОВНО один блок из [length] цифр.
///
/// Два блока (код и, скажем, номер заказа) или цифры другой длины — это
/// неоднозначность: лучше не вставить ничего и дать человеку ввести код
/// руками, чем подставить чужие цифры.
String? extractSmsCode(String sms, {int length = 6}) {
  final matches = RegExp(
    '(?<!\\d)\\d{$length}(?!\\d)',
  ).allMatches(sms).map((m) => m.group(0)!).toSet();
  return matches.length == 1 ? matches.first : null;
}

/// Источник кода из входящей СМС. Шов для тестов: плагин в `flutter test`
/// не инициализируется.
abstract class SmsCodeSource {
  /// Ждёт СМС с кодом. `null` — не дождались, отменили или код не опознан.
  Future<String?> next();

  /// Снимает ожидание (в том числе отложенное нативное).
  Future<void> cancel();
}

/// Android: SMS User Consent API. Система сама показывает диалог «Разрешить
/// Liza прочитать это сообщение?», разрешения READ_SMS и app-hash в тексте не
/// нужны. `senderPhoneNumber` не задаём: номер отправителя otpverification
/// неизвестен, а ошибочный фильтр молча отрежет все СМС.
class AndroidSmsCodeSource implements SmsCodeSource {
  AndroidSmsCodeSource({this.length = 6});

  final int length;

  @override
  Future<String?> next() async {
    try {
      final result = await SmartAuth.instance.getSmsWithUserConsentApi();
      final sms = result.data?.sms;
      return sms == null ? null : extractSmsCode(sms, length: length);
    } catch (e) {
      // Нет Play Services / плагина — остаётся ручной ввод и вставка.
      debugPrint('SMS User Consent недоступен: $e');
      return null;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await SmartAuth.instance.removeUserConsentApiListener();
    } catch (_) {}
  }
}
