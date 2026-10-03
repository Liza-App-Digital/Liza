import 'dart:async';

import 'package:matrix/matrix.dart';

import 'story_model.dart';

/// Итог «Копировать ссылку»: ссылка в буфере либо её надо отдать
/// пользователю для ручного копирования (браузер запретил запись).
class StoryLinkCopyResult {
  final String url;
  final bool copied;

  const StoryLinkCopyResult.copied(this.url) : copied = true;
  const StoryLinkCopyResult.manual(this.url) : copied = false;

  @override
  bool operator ==(Object other) =>
      other is StoryLinkCopyResult &&
      other.url == url &&
      other.copied == copied;

  @override
  int get hashCode => Object.hash(url, copied);

  @override
  String toString() => 'StoryLinkCopyResult(${copied ? 'copied' : 'manual'})';
}

/// Короткие ссылки на сегменты сторис с префетчем (LABA-2615).
///
/// Flutter Web пишет в буфер голым `navigator.clipboard.writeText`, а браузер
/// пропускает запись только внутри жеста пользователя и при фокусе документа.
/// Запись после сетевого `await` (Safari) или при фокусе в DevTools
/// отвергается. Поэтому ссылку запрашиваем заранее — при открытии меню, — а
/// при выборе пункта пишем в буфер синхронно; если запись всё же отвергнута,
/// вызывающий показывает ссылку для ручного копирования.
class StoryLinkCopier {
  final Future<String> Function(StoryRef ref) createLink;

  final Map<String, Future<String>> _pending = {};
  final Map<String, String> _ready = {};

  StoryLinkCopier({required this.createLink});

  /// Запускает создание ссылки один раз на сегмент. Ошибка не кэшируется:
  /// следующий вызов повторит запрос.
  Future<String> prefetch(StoryRef ref) {
    final id = ref.eventId;
    final ready = _ready[id];
    if (ready != null) return Future.value(ready);
    return _pending.putIfAbsent(id, () {
      final future = createLink(ref);
      // Обработчик вешаем сразу: брошенный префетч (меню закрыли без выбора)
      // иначе уронил бы ошибку в зону как необработанную.
      future.then(
        (url) {
          _ready[id] = url;
          _pending.remove(id);
        },
        onError: (Object e, StackTrace s) {
          _pending.remove(id);
          Logs().w('Story link prefetch failed', e, s);
        },
      );
      return future;
    });
  }

  /// Кладёт ссылку сегмента в буфер. Готовую ссылку пишет синхронно, до
  /// первого `await` — пока жест тапа ещё действует. Ошибку сети пробрасывает.
  Future<StoryLinkCopyResult> copy(
    StoryRef ref, {
    required Future<void> Function(String text) setClipboard,
  }) async {
    final ready = _ready[ref.eventId];
    if (ready != null) return _write(ready, setClipboard);
    return _write(await prefetch(ref), setClipboard);
  }

  Future<StoryLinkCopyResult> _write(
    String url,
    Future<void> Function(String text) setClipboard,
  ) async {
    try {
      await setClipboard(url);
      return StoryLinkCopyResult.copied(url);
    } catch (e, s) {
      Logs().w('Story link clipboard write rejected', e, s);
      return StoryLinkCopyResult.manual(url);
    }
  }
}
