import 'dart:convert';

import 'package:liza/utils/push_journal.dart';

/// Закрытые диагностические признаки; имя файла и текст не используются.
PushMediaKind pushMediaKind(String? msgtype, {bool isVoice = false}) =>
    switch (msgtype) {
      null || '' => PushMediaKind.unknown,
      'm.audio' => isVoice ? PushMediaKind.voice : PushMediaKind.audio,
      _ => PushMediaKind.other,
    };

/// Preview не содержит исходного relation. Не выдаём отсутствие поля за none.
PushMediaKind pushApnsMediaKind(Map<String, dynamic> raw) {
  if (raw['type'] == 'm.room.encrypted') return PushMediaKind.unknown;
  Object? content = raw['content'];
  if (content is String && content.length <= 8192) {
    try {
      content = jsonDecode(content);
    } catch (_) {
      return PushMediaKind.unknown;
    }
  }
  if (content is! Map) return PushMediaKind.unknown;
  return pushMediaKind(
    content['msgtype'] is String ? content['msgtype'] as String : null,
    isVoice: content['voice'] == true,
  );
}

/// Только для содержимого локального события, не для усечённого APNs preview.
({PushRelationKind kind, String? targetId}) pushLocalRelation(Object? raw) {
  if (raw == null) return (kind: PushRelationKind.none, targetId: null);
  if (raw is! Map) return (kind: PushRelationKind.unknown, targetId: null);
  final reply = raw['m.in_reply_to'];
  final target = raw['event_id'];
  final replyTarget = reply is Map ? reply['event_id'] : null;
  final kind = switch (raw['rel_type']) {
    'm.replace' => PushRelationKind.replace,
    'm.thread' => PushRelationKind.thread,
    'm.annotation' => PushRelationKind.annotation,
    null when reply is Map => PushRelationKind.reply,
    null => PushRelationKind.unknown,
    _ => PushRelationKind.other,
  };
  final candidate = target is String ? target : replyTarget;
  return (
    kind: kind,
    targetId: candidate is String && candidate.isNotEmpty ? candidate : null,
  );
}
