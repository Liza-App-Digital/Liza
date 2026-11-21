import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liza/utils/xl_credentials.dart';

/// Подменяет AES-CTR простым XOR: настоящая реализация из vodozemac требует
/// нативную библиотеку, которая в host-тестах не грузится.
Uint8List _fakeAesCtr({
  required Uint8List input,
  required Uint8List key,
  required Uint8List iv,
}) {
  final out = Uint8List(input.length);
  for (var i = 0; i < input.length; i++) {
    out[i] = input[i] ^ key[i % key.length];
  }
  return out;
}

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
  final iv = Uint8List.fromList(List<int>.filled(16, 7));

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

  group('шифрование', () {
    test('расшифровка возвращает исходный ключ', () {
      const plain = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9';
      final encoded =
          XlCredentials.encryptKey(plain, key, iv, aesCtr: _fakeAesCtr);
      final decoded =
          XlCredentials.decryptKey(encoded, key, iv, aesCtr: _fakeAesCtr);

      expect(decoded, plain);
    });

    test('шифротекст не содержит исходный ключ в открытом виде', () {
      const plain = 'eyJhbGciOiJIUzI1NiJ9';
      final encoded =
          XlCredentials.encryptKey(plain, key, iv, aesCtr: _fakeAesCtr);

      expect(encoded, isNot(contains(plain)));
      expect(utf8.decode(base64Decode(encoded), allowMalformed: true),
          isNot(equals(plain)));
    });

    test('пустой ключ шифруется и расшифровывается без ошибок', () {
      final encoded = XlCredentials.encryptKey('', key, iv, aesCtr: _fakeAesCtr);
      expect(XlCredentials.decryptKey(encoded, key, iv, aesCtr: _fakeAesCtr), '');
    });

    test('кириллица переживает цикл шифрования', () {
      const plain = 'ключ-тест-Ключ';
      final encoded =
          XlCredentials.encryptKey(plain, key, iv, aesCtr: _fakeAesCtr);
      expect(XlCredentials.decryptKey(encoded, key, iv, aesCtr: _fakeAesCtr),
          plain);
    });
  });

  test('статус XL — отдельное state-событие, не account_data', () {
    expect(xlStatusStateType, 'com.liza.xl.status');
  });
}
