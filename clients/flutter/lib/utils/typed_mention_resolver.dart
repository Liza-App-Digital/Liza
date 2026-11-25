import 'package:matrix/matrix.dart';
import 'package:slugify/slugify.dart';

/// Один кандидат на упоминание: его «пилюля» ([User.mention], напр.
/// `@[Дмитрий Луба]`) и набор строчных токенов, по которым набранный от руки
/// `@токен` считается указанием на этого участника (слова имени, slug, localpart).
class MentionCandidate {
  final String pill;
  final Set<String> tokens;
  const MentionCandidate({required this.pill, required this.tokens});
}

/// Дорезолвивание упоминаний, набранных РУКАМИ (`@Имя`), в полноценные пилюли
/// `@[Отображаемое имя]` ПЕРЕД отправкой.
///
/// Почему: подсветку чата в красный (`room.highlightCount > 0`) на приёме
/// поднимает серверное правило `.m.rule.is_user_mention` — и только если mxid
/// адресата лежит в `m.mentions.user_ids`. Этот список SDK формирует на отправке,
/// резолвя `@`-токены через `Room.getMention`, который матчит ТОЛЬКО точную
/// пилюлю `@[Полное имя]` (см. `User.mentionFragments`). Набранный `@Дмитрий`
/// (по имени/частично, без выбора подсказки) не резолвится → в `m.mentions` не
/// попадает → у адресата счётчик синий, а не красный (LABA-1897).
///
/// Мы переписываем такой `@токен` в пилюлю, но ТОЛЬКО когда он однозначно
/// указывает на одного участника — иначе оставляем как есть, чтобы не тегнуть
/// не того человека.
class TypedMentionResolver {
  // Начало упоминания — как в автоподсказке: начало строки или пробел, затем
  // `@` и токен из букв/цифр/`._-`. Существующие пилюли `@[...]` и mxid
  // `@user:server` этим не захватываются (`[` и `:` вне класса токена).
  static final RegExp _mentionRegex = RegExp(
    r'(^|\s)@([\p{L}\p{N}._-]+)',
    unicode: true,
    multiLine: true,
  );

  static String resolve(String text, List<MentionCandidate> candidates) {
    if (candidates.isEmpty || !text.contains('@')) return text;
    return text.replaceAllMapped(_mentionRegex, (match) {
      final whole = match.group(0)!;
      final lead = match.group(1)!;
      final token = match.group(2)!;
      // Похоже на mxid (`@localpart:server`) — отдаём SDK как есть.
      if (match.end < text.length && text[match.end] == ':') return whole;
      final key = token.toLowerCase();
      if (key == 'room') return whole;
      final matches = candidates.where((c) => c.tokens.contains(key)).toList();
      if (matches.length != 1) return whole;
      return '$lead${matches.first.pill}';
    });
  }

  /// Собирает кандидатов из участников комнаты. Себя исключаем: себя не тегаем.
  static List<MentionCandidate> candidatesFrom(
    Iterable<User> participants,
    String? ownUserId,
  ) {
    final result = <MentionCandidate>[];
    for (final user in participants) {
      if (user.id == ownUserId) continue;
      final tokens = <String>{};
      final displayName = user.displayName;
      if (displayName != null && displayName.isNotEmpty) {
        for (final word in displayName.toLowerCase().split(RegExp(r'\s+'))) {
          if (word.length >= 2) tokens.add(word);
        }
        final slug = slugify(displayName.toLowerCase());
        if (slug.length >= 2) tokens.add(slug);
      }
      final localpart = user.id
          .split(':')
          .first
          .replaceFirst('@', '')
          .toLowerCase();
      if (localpart.length >= 2) tokens.add(localpart);
      if (tokens.isEmpty) continue;
      result.add(MentionCandidate(pill: user.mention, tokens: tokens));
    }
    return result;
  }

  /// Удобная обёртка над двумя шагами.
  static String resolveForRoom(String text, Room room) =>
      resolve(text, candidatesFrom(room.getParticipants(), room.client.userID));

  /// Реплика блока `addMentions` из SDK `Room.sendTextEvent` (matrix-4.1.0
  /// `room.dart:738-770`). Нужна, когда форматированное сообщение уходит через
  /// `room.sendEvent` В ОБХОД `sendTextEvent` (тот строит `m.mentions` сам, но
  /// умеет только `parseMarkdown`-путь). Без ручной сборки `m.mentions.user_ids`
  /// у адресата счётчик синий вместо красного — правило `.m.rule.is_user_mention`
  /// не срабатывает (INV-2 спеки формата).
  static Map<String, dynamic>? buildMentions(
    String message,
    Room room, {
    Event? inReplyTo,
  }) {
    var potentialMentions =
        message
            .split('@')
            .map(
              (text) => text.startsWith('[')
                  ? '@${text.split(']').first}]'
                  : '@${text.split(RegExp(r'\s+')).first}',
            )
            .toList()
          ..removeAt(0);

    final hasRoomMention = potentialMentions.remove('@room');

    potentialMentions =
        potentialMentions
            .map(
              (mention) =>
                  mention.isValidMatrixId ? mention : room.getMention(mention),
            )
            .nonNulls
            .toSet()
            .toList()
          ..remove(room.client.userID);

    if (inReplyTo != null) potentialMentions.add(inReplyTo.senderId);

    if (!hasRoomMention && potentialMentions.isEmpty) return null;
    return {
      if (hasRoomMention) 'room': true,
      if (potentialMentions.isNotEmpty) 'user_ids': potentialMentions,
    };
  }

  /// Content ПРАВКИ текста для `room.sendEvent(..., editEventId:)`. Правка никого
  /// не пингует (как в Telegram): SDK копирует content и наверх события, и в
  /// `m.new_content`, а `.m.rule.is_user_mention` в Synapse стоит РАНЬШЕ
  /// `.m.rule.suppress_edits` — полный набор упоминаний наверху подсветил бы
  /// адресатов повторно. `sendTextEvent` для правок поэтому не годится: он сам
  /// кладёт найденные упоминания. Пустой ключ — явное «никого» (MSC3952).
  static Map<String, Object?> editTextContent(String body) => {
    'msgtype': MessageTypes.Text,
    'body': body,
    'm.mentions': <String, Object?>{},
  };

  /// Поля `extraContent` для медиа-ОТВЕТА (голосовое): `sendFileEvent` SDK, в
  /// отличие от `sendTextEvent`, не кладёт автора ответа в `m.mentions`. После
  /// Synapse ≥1.164 (MSC4210) подсветку даёт только явный `m.mentions` — без него
  /// голосовой ответ не уведомлял бы автора (в Telegram ответ уведомляет).
  /// Ответ самому себе — без ключа.
  static Map<String, Object?> replyMentionsExtra(
    Event? inReplyTo,
    String? myUserId,
  ) {
    final sender = inReplyTo?.senderId;
    if (sender == null || sender == myUserId) return const {};
    return {
      'm.mentions': <String, Object?>{
        'user_ids': [sender],
      },
    };
  }
}
