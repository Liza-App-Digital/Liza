import 'dart:async';

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/stories/story_link_copier.dart';
import 'package:liza/utils/stories/story_model.dart';

StoryRef _ref(String eventId) => StoryRef(
  roomId: '!stories:example.invalid',
  eventId: eventId,
  authorId: '@author:example.invalid',
  expiresTs: 1751800000000,
);

const _url = 'https://me.liza.ru/s/p_abc';

void main() {
  group('StoryLinkCopier [ledger:RL-stories-link]', () {
    test(
      'один запрос на eventId, другой eventId - новый [AC:RL-stories-link/1]',
      () async {
        final calls = <String>[];
        final copier = StoryLinkCopier(
          createLink: (ref) async {
            calls.add(ref.eventId);
            return '$_url-${ref.eventId}';
          },
        );
        copier.prefetch(_ref(r'$a'));
        copier.prefetch(_ref(r'$a'));
        await copier.prefetch(_ref(r'$a'));
        await copier.copy(_ref(r'$a'), setClipboard: (_) async {});
        await copier.prefetch(_ref(r'$b'));
        expect(calls, [r'$a', r'$b']);
      },
    );

    test('ссылка готова - буфер пишется синхронно, до первого await '
        '[AC:RL-stories-link/2]', () async {
      final copier = StoryLinkCopier(createLink: (_) async => _url);
      await copier.prefetch(_ref(r'$a'));

      final written = <String>[];
      // Не ждём copy(): запись обязана случиться ДО возврата управления —
      // на Web браузер разрешает writeText только внутри жеста тапа.
      final result = copier.copy(
        _ref(r'$a'),
        setClipboard: (text) async => written.add(text),
      );
      expect(written, [_url]);
      expect(await result, StoryLinkCopyResult.copied(_url));
    });

    test('отказ буфера - ссылка уходит в ручное копирование, без исключения '
        '[AC:RL-stories-link/3]', () async {
      final copier = StoryLinkCopier(createLink: (_) async => _url);
      await copier.prefetch(_ref(r'$a'));
      final result = await copier.copy(
        _ref(r'$a'),
        setClipboard: (_) async => throw PlatformException(code: 'copy_fail'),
      );
      expect(result, StoryLinkCopyResult.manual(_url));
    });

    test('ссылка не готова - после ответа сервера запись всё равно пробуется '
        '[AC:RL-stories-link/4]', () async {
      final server = Completer<String>();
      final copier = StoryLinkCopier(createLink: (_) => server.future);
      copier.prefetch(_ref(r'$a'));

      final written = <String>[];
      final ok = copier.copy(
        _ref(r'$a'),
        setClipboard: (text) async => written.add(text),
      );
      expect(written, isEmpty);
      server.complete(_url);
      expect(await ok, StoryLinkCopyResult.copied(_url));
      expect(written, [_url]);
    });

    test(
      'не готова и буфер отказал - ручное копирование [AC:RL-stories-link/4]',
      () async {
        final copier = StoryLinkCopier(createLink: (_) async => _url);
        final result = await copier.copy(
          _ref(r'$a'),
          setClipboard: (_) async => throw PlatformException(code: 'copy_fail'),
        );
        expect(result, StoryLinkCopyResult.manual(_url));
      },
    );

    test('ошибка сети - наружу, не кэшируется, брошенный префетч не даёт '
        'необработанной ошибки [AC:RL-stories-link/5]', () async {
      var attempt = 0;
      final copier = StoryLinkCopier(
        createLink: (_) async {
          attempt++;
          if (attempt == 1) throw Exception('HTTP 500');
          return _url;
        },
      );
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        copier.prefetch(_ref(r'$a'));
        await pumpEventQueue();
      }, (e, _) => uncaught.add(e));
      expect(uncaught, isEmpty);

      final result = await copier.copy(_ref(r'$a'), setClipboard: (_) async {});
      expect(result, StoryLinkCopyResult.copied(_url));
      expect(attempt, 2);
    });

    test('ошибка сети при копировании летит наружу [AC:RL-stories-link/5]', () {
      final copier = StoryLinkCopier(
        createLink: (_) async => throw Exception('offline'),
      );
      expect(
        copier.copy(_ref(r'$a'), setClipboard: (_) async {}),
        throwsException,
      );
    });
  });
}
