import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:matrix/matrix.dart';
// ignore: depend_on_referenced_packages
import 'package:vodozemac/vodozemac.dart';

import 'package:liza/utils/secure_storage.dart';

/// Подпись AES-CTR из vodozemac. Вынесена в typedef, чтобы тесты подменяли
/// реализацию: нативная библиотека в host-`flutter test` не грузится
/// (тот же приём, что в `e2ee_media_proxy.dart`).
typedef AesCtrFn =
    Uint8List Function({
      required Uint8List input,
      required Uint8List key,
      required Uint8List iv,
    });

/// Тип account_data, где лежит зашифрованный API-ключ XL.
const String xlCredentialsAccountDataType = 'com.liza.xl.credentials';

/// msgtype служебного события, которым ключ доезжает до бота.
const String xlCredentialsMsgtype = 'com.liza.xl.credentials';

/// Состояние XL на сервере (state-event в основном DM с Лизой). Источник
/// истины для карточки: локальный account_data может не расшифроваться после
/// переустановки, а ключ в XL-боте при этом жив.
const String xlStatusStateType = 'com.liza.xl.status';

/// Ключ в `flutterSecureStorage`, под которым хранится локальный AES-ключ
/// шифрования account_data-записи с ключом XL.
const String _xlEncryptionKeyStorageKey = 'xl_credentials_encryption_key';

/// Работа с API-ключом XL: шифрование для account_data и упаковка в событие.
///
/// Ключ равносилен полному доступу к кабинету мерчанта, поэтому в
/// account_data кладётся только шифротекст, а до бота он едет служебным
/// событием внутри E2EE-комнаты.
abstract final class XlCredentials {
  /// Служебное событие с ключом для бота.
  static Map<String, Object?> buildEvent(String apiKey) => {
    'msgtype': xlCredentialsMsgtype,
    'body': 'Подключение интеграции XL',
    'xl_api_key': apiKey.trim(),
  };

  /// Шифрует ключ и кодирует в base64 для хранения в account_data.
  ///
  /// ⚠️ [iv] ОБЯЗАН быть свежим случайным значением на КАЖДЫЙ вызов с тем же
  /// [key]. AES-CTR — потоковый шифр: повторное использование пары (key, iv)
  /// для разных данных вскрывает исходный текст через XOR шифротекстов.
  /// Сохранённый в account_data iv годится ТОЛЬКО для расшифровки уже
  /// записанного значения — для нового шифрования генерируй новый.
  static String encryptKey(
    String plain,
    Uint8List key,
    Uint8List iv, {
    AesCtrFn? aesCtr,
  }) {
    final impl = aesCtr ?? _defaultAesCtr;
    final cipher = impl(
      input: Uint8List.fromList(utf8.encode(plain)),
      key: key,
      iv: iv,
    );
    return base64Encode(cipher);
  }

  /// Обратная операция к [encryptKey].
  ///
  /// [iv] здесь — тот, что сохранён рядом с шифротекстом. Для нового
  /// шифрования его переиспользовать нельзя (см. предупреждение в [encryptKey]).
  static String decryptKey(
    String encoded,
    Uint8List key,
    Uint8List iv, {
    AesCtrFn? aesCtr,
  }) {
    final impl = aesCtr ?? _defaultAesCtr;
    final plain = impl(input: base64Decode(encoded), key: key, iv: iv);
    return utf8.decode(plain);
  }

  static AesCtrFn get _defaultAesCtr => _vodozemacAesCtr;

  /// Локальный AES-ключ шифрования account_data-записи. Живёт в Keychain/
  /// secure storage устройства (НЕ в account_data — иначе шифрование теряет
  /// смысл), генерируется один раз и переиспользуется на все последующие
  /// `save()`. IV — в отличие от ключа — генерируется заново на каждый вызов
  /// [encryptKey], см. предупреждение там.
  static Future<Uint8List> getOrCreateEncryptionKey() async {
    final stored = await flutterSecureStorage.read(
      key: _xlEncryptionKeyStorageKey,
    );
    if (stored != null) return base64Decode(stored);

    final rng = Random.secure();
    final key = Uint8List(32);
    key.setAll(0, Iterable.generate(key.length, (_) => rng.nextInt(256)));
    await flutterSecureStorage.write(
      key: _xlEncryptionKeyStorageKey,
      value: base64Encode(key),
    );
    return key;
  }

  /// Свежий случайный IV для очередного [encryptKey] (не путать с ключом
  /// шифрования — см. [getOrCreateEncryptionKey]).
  static Uint8List generateIv() {
    final rng = Random.secure();
    final iv = Uint8List(16);
    iv.setAll(0, Iterable.generate(iv.length, (_) => rng.nextInt(256)));
    return iv;
  }

  /// Читает и расшифровывает сохранённый ключ XL из account_data клиента.
  ///
  /// `null`, если интеграция не подключена ИЛИ запись повреждена (ключ/IV не
  /// совпали с локальным AES-ключом — например, Keychain очистился после
  /// переустановки приложения). Во втором случае вызывающая сторона обязана
  /// трактовать это как «подключите заново», а не ронять экран/чат.
  static Future<String?> readStoredKey(Client client) async {
    final content = client.accountData[xlCredentialsAccountDataType]?.content;
    final encoded = content?.tryGet<String>('key');
    final ivBase64 = content?.tryGet<String>('iv');
    if (encoded == null || ivBase64 == null) return null;

    final encryptionKey = await getOrCreateEncryptionKey();
    try {
      return decryptKey(encoded, encryptionKey, base64Decode(ivBase64));
    } on FormatException {
      return null;
    }
  }
}

/// Состояние подключения XL в Matrix: так карточка не зависит от локального Keychain.
abstract final class XlStatus {
  static Future<bool?> fetch(Room room) async {
    try {
      final content = await room.client
          .getRoomStateWithKey(room.id, xlStatusStateType, '')
          .timeout(const Duration(seconds: 15));
      return content['connected'] == true;
    } on MatrixException catch (e) {
      if (e.errcode == 'M_NOT_FOUND') return null;
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(Room room, bool connected) =>
      room.client.setRoomStateWithKey(room.id, xlStatusStateType, '', {
        'connected': connected,
      });
}

/// Боевая реализация: AES-256-CTR из vodozemac (тот же примитив, что у
/// зашифрованных вложений).
Uint8List _vodozemacAesCtr({
  required Uint8List input,
  required Uint8List key,
  required Uint8List iv,
}) => CryptoUtils.aesCtr(input: input, key: key, iv: iv);
