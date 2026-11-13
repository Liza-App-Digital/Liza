import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';

/// Блок виджета Telegram (Bot API 10.4) внутри `m.room.message`.
///
/// Формат — wire contract D13 (`openspec/changes/liza-telegram-widgets`):
/// сервер пишет его по тому же документу, поэтому имена полей не трогать.
class TgWidgetBlock {
  static const String contentKey = 'com.liza.widget';
  static const String silentKey = 'com.liza.widget.silent';

  final int v;
  final String widgetId;
  final String botId;
  final String sender;
  final String roomId;
  final String html;
  final int width;
  final int height;
  final bool isShared;
  final bool allowQueries;

  /// Подписан: пересылка/копирование запрещены ботом независимо от scope.
  final bool protectContent;
  final String? chatData;
  final String? publicData;
  final String kid;
  final String sig;

  /// Поле не подписано: сервер ставит `false`, когда подписи нет и `body`
  /// содержит лишь заглушку «Виджет». Отсутствие поля = подпись есть.
  final bool hasCaption;

  const TgWidgetBlock({
    required this.v,
    required this.widgetId,
    required this.botId,
    required this.sender,
    required this.roomId,
    required this.html,
    required this.width,
    required this.height,
    required this.isShared,
    required this.allowQueries,
    required this.protectContent,
    required this.chatData,
    required this.publicData,
    required this.kid,
    required this.sig,
    this.hasCaption = true,
  });

  /// `null` — блока нет или он не по контракту: такое сообщение рисуется
  /// обычным текстом (`body`), код не исполняется.
  static TgWidgetBlock? tryParse(Object? raw) {
    if (raw is! Map) return null;
    String? str(String k) {
      final value = raw[k];
      return value is String ? value : null;
    }

    int? integer(String k) {
      final value = raw[k];
      return value is int && value >= 0 ? value : null;
    }

    String? state(String k) {
      final value = raw[k];
      if (value is String && value.isNotEmpty) return value;
      return null;
    }

    final v = raw['v'];
    final widgetId = str('widget_id');
    final botId = str('bot_id');
    final sender = str('sender');
    final roomId = str('room_id');
    final html = str('html');
    final width = integer('width');
    final height = integer('height');
    final isShared = raw['is_shared'];
    final allowQueries = raw['allow_queries'];
    final protectContent = raw['protect_content'];
    final kid = str('kid');
    final sig = str('sig');
    if (v != 1 ||
        widgetId == null ||
        widgetId.isEmpty ||
        botId == null ||
        sender == null ||
        roomId == null ||
        html == null ||
        width == null ||
        height == null ||
        isShared is! bool ||
        allowQueries is! bool ||
        protectContent is! bool ||
        kid == null ||
        sig == null ||
        sig.isEmpty) {
      return null;
    }
    return TgWidgetBlock(
      v: 1,
      widgetId: widgetId,
      botId: botId,
      sender: sender,
      roomId: roomId,
      html: html,
      width: width,
      height: height,
      isShared: isShared,
      allowQueries: allowQueries,
      protectContent: protectContent,
      chatData: state('chat_data'),
      publicData: state('public_data'),
      kid: kid,
      sig: sig,
      hasCaption: raw['has_caption'] != false,
    );
  }

  static TgWidgetBlock? fromEvent(Event event) {
    if (event.type != EventTypes.Message || event.redacted) return null;
    return tryParse(event.content[contentKey]);
  }

  String get htmlSha256 => sha256.convert(utf8.encode(html)).toString();

  /// Подписанные байты D13: канонический JSON (ключи по алфавиту, без
  /// пробелов, не-ASCII как есть). `jsonEncode` Dart не экранирует не-ASCII и
  /// пишет целые без `.0` — совпадает с `json.dumps(ensure_ascii=False)`.
  String signedPayload() {
    final payload = <String, Object>{
      'allow_queries': allowQueries,
      'bot_id': botId,
      'height': height,
      'html_sha256': htmlSha256,
      'is_shared': isShared,
      'protect_content': protectContent,
      'room_id': roomId,
      'sender': sender,
      'v': v,
      'widget_id': widgetId,
      'width': width,
    };
    return jsonEncode(payload);
  }

  TgWidgetBlock withState({String? chatData, String? publicData}) =>
      TgWidgetBlock(
        v: v,
        widgetId: widgetId,
        botId: botId,
        sender: sender,
        roomId: roomId,
        html: html,
        width: width,
        height: height,
        isShared: isShared,
        allowQueries: allowQueries,
        protectContent: protectContent,
        chatData: chatData,
        publicData: publicData,
        kid: kid,
        sig: sig,
        hasCaption: hasCaption,
      );
}

bool isTgWidgetEvent(Event event) => TgWidgetBlock.fromEvent(event) != null;

/// Состояние виджета: код, размеры и подпись — ТОЛЬКО из исходного события,
/// `chat_data`/`public_data` — из самой новой правки того же отправителя.
/// Иначе правка (её может прислать кто угодно с тем же `m.relates_to`)
/// подменила бы исполняемый HTML.
TgWidgetBlock? resolveTgWidgetState(Event original, Timeline? timeline) {
  final base = TgWidgetBlock.fromEvent(original);
  if (base == null || timeline == null) return base;
  if (!original.hasAggregatedEvents(timeline, RelationshipTypes.edit)) {
    return base;
  }
  final edits =
      original
          .aggregatedEvents(timeline, RelationshipTypes.edit)
          .where(
            (e) =>
                e.senderId == original.senderId && e.type == EventTypes.Message,
          )
          .toList()
        ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
  for (final edit in edits.reversed) {
    final newContent = edit.content['m.new_content'];
    if (newContent is! Map) continue;
    final block = newContent[TgWidgetBlock.contentKey];
    if (block is! Map) continue;
    String? state(String k) {
      final value = block[k];
      return value is String && value.isNotEmpty ? value : null;
    }

    return base.withState(
      chatData: state('chat_data'),
      publicData: state('public_data'),
    );
  }
  return base;
}

/// Размеры пузыря профиля 1: ширина 200–600 (0 = по ширине пузыря), высота
/// 50–600 (0 = по содержимому).
abstract final class TgWidgetSize {
  static const double minWidth = 200;
  static const double maxWidth = 600;
  static const double minHeight = 50;
  static const double maxHeight = 600;

  static double clampHeight(num h) =>
      h.toDouble().clamp(minHeight, maxHeight).toDouble();

  /// Высота, которую резервируем ДО загрузки: `height` или 50 при авто.
  /// Резерв нужен, чтобы появление виджета не сдвигало reverse-ленту.
  static double reservedHeight(TgWidgetBlock block) =>
      block.height == 0 ? minHeight : clampHeight(block.height);
}
