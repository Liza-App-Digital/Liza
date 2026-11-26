import 'package:flutter_test/flutter_test.dart';
import 'package:liza/utils/xl_credentials.dart';

void main() {
  group('XlCredentials.buildEvent', () {
    test('содержит msgtype, ключ и человекочитаемый fallback', () {
      final event = XlCredentials.buildEvent('eyJhbGciOiJIUzI1NiJ9');

      expect(event['msgtype'], xlCredentialsMsgtype);
      expect(event['xl_api_key'], 'eyJhbGciOiJIUzI1NiJ9');
      expect(event['body'], isNotEmpty);
    });

    test('обрезает пробелы вокруг вставленного ключа', () {
      final event = XlCredentials.buildEvent('  eyJhbGci  ');
      expect(event['xl_api_key'], 'eyJhbGci');
    });
  });

  group('XlStatusInfo (серверный статус)', () {
    test('подключено: ключ сохранён и проверен', () {
      final info = XlStatusInfo.fromContent({
        'connected': true,
        'key_saved': true,
        'error': '',
      });
      expect(info.connected, isTrue);
      expect(info.keySaved, isTrue);
      expect(info.error, isEmpty);
    });

    test('ключ сохранён, но сервис недоступен — карточка не врёт', () {
      final info = XlStatusInfo.fromContent({
        'connected': false,
        'key_saved': true,
        'error': 'unavailable',
      });
      expect(info.connected, isFalse);
      expect(info.keySaved, isTrue);
      expect(info.error, 'unavailable');
    });

    test('невалидный ключ', () {
      final info = XlStatusInfo.fromContent({
        'connected': false,
        'key_saved': false,
        'error': 'invalid_key',
      });
      expect(info.connected, isFalse);
      expect(info.error, 'invalid_key');
    });

    test('без полей — отключено, без исключения', () {
      final info = XlStatusInfo.fromContent({});
      expect(info.connected, isFalse);
      expect(info.keySaved, isFalse);
      expect(info.error, isEmpty);
    });
  });
}
