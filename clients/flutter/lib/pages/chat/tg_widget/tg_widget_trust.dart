import 'package:matrix/matrix.dart';
// ignore: depend_on_referenced_packages
import 'package:vodozemac/vodozemac.dart' as vod;

import 'package:liza/pages/chat/tg_widget/tg_widget_model.dart';

/// Проверка Ed25519-подписи виджета. Интерфейс — ради `flutter test`: нативная
/// библиотека vodozemac на хосте может не загрузиться.
abstract class TgWidgetSignatureVerifier {
  bool verify({
    required String publicKey,
    required String message,
    required String signature,
  });
}

class VodozemacTgWidgetVerifier implements TgWidgetSignatureVerifier {
  const VodozemacTgWidgetVerifier();

  @override
  bool verify({
    required String publicKey,
    required String message,
    required String signature,
  }) {
    try {
      vod.Ed25519PublicKey.fromBase64(publicKey).verify(
        message: message,
        signature: vod.Ed25519Signature.fromBase64(signature),
      );
      return true;
    } catch (e) {
      Logs().v('[TgWidget] подпись не прошла: ${e.runtimeType}');
      return false;
    }
  }
}

enum TgWidgetTrustKind {
  /// Подпись не сошлась (или ключ неизвестен) — только подпись, код не
  /// исполняется, движок не создаётся.
  captionOnly,

  /// Подпись верна, отправитель и комната совпадают с подписанными.
  original,

  /// Подпись верна, но копия лежит у другого отправителя или в другом чате.
  forwarded,
}

/// D4/D13: «оригинал» = подпись верна ∧ отправитель события == `sender` ∧
/// комната события == `room_id`. Любая другая верная копия — пересланная.
TgWidgetTrustKind evaluateTgWidgetTrust({
  required TgWidgetBlock block,
  required String eventSender,
  required String eventRoomId,
  required Map<String, String> keys,
  required TgWidgetSignatureVerifier verifier,
}) {
  final key = keys[block.kid];
  if (key == null) return TgWidgetTrustKind.captionOnly;
  final ok = verifier.verify(
    publicKey: key,
    message: block.signedPayload(),
    signature: block.sig,
  );
  if (!ok) return TgWidgetTrustKind.captionOnly;
  if (eventSender == block.sender && eventRoomId == block.roomId) {
    return TgWidgetTrustKind.original;
  }
  return TgWidgetTrustKind.forwarded;
}
