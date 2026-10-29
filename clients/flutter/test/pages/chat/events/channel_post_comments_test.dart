import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/channel_post_comments.dart';

// Плашка комментариев под постом канала. Рендер самой плашки проверяем
// виджет-тестом (для него хватает счётчика и колбэка), а гейты «только в
// канале с комментариями» и снятие подписки на таймлайн обсуждения —
// структурно: собрать настоящие Room/Event требует поднятого клиента.

Future<void> _pump(
  WidgetTester tester,
  int count, {
  VoidCallback? onTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: const [
        L10n.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: ChannelPostCommentsBar(count: count, onTap: onTap ?? () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('ChannelPostCommentsBar', () {
    testWidgets('без комментариев зовёт оставить первый', (tester) async {
      await _pump(tester, 0);
      expect(find.text('Прокомментировать'), findsOneWidget);
    });

    testWidgets('русский plural: формы one/few/many', (tester) async {
      // Гейта на полноту intl_ru.arb нет — при отсутствии ключа Flutter молча
      // подставит английский. Ловим это рендером.
      await _pump(tester, 1);
      expect(find.text('1 комментарий'), findsOneWidget);
      await _pump(tester, 3);
      expect(find.text('3 комментария'), findsOneWidget);
      await _pump(tester, 12);
      expect(find.text('12 комментариев'), findsOneWidget);
    });

    testWidgets('рисует иконку комментария', (tester) async {
      await _pump(tester, 4);
      expect(find.byIcon(Icons.mode_comment_outlined), findsOneWidget);
    });

    testWidgets('тап дёргает onTap', (tester) async {
      var taps = 0;
      await _pump(tester, 2, onTap: () => taps++);
      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });

  group('ключи локализации', () {
    // Рендером проверить обе локали в одном процессе нельзя: L10n грузится
    // deferred-библиотеками, и вторая локаль в тестовой VM уже не подгружается
    // (дерево остаётся пустым). Поэтому наличие ключей в обоих ARB — по файлам.
    test('оба ключа заведены и в en, и в ru', () {
      for (final path in ['lib/l10n/intl_en.arb', 'lib/l10n/intl_ru.arb']) {
        final source = File(path).readAsStringSync();
        expect(
          source.contains('"channelCommentsCount"'),
          isTrue,
          reason: 'без ключа в $path Flutter молча подставит английский',
        );
        expect(
          source.contains('"channelAddComment"'),
          isTrue,
          reason: 'без ключа в $path Flutter молча подставит английский',
        );
      }
    });

    test('русский plural несёт все формы one/few/many/other', () {
      final ru = File('lib/l10n/intl_ru.arb').readAsStringSync();
      final line = ru
          .split('\n')
          .firstWhere((l) => l.contains('"channelCommentsCount"'));
      for (final form in ['one{', 'few{', 'many{', 'other{']) {
        expect(line.contains(form), isTrue, reason: 'нет формы $form');
      }
    });
  });

  group('гейты плашки в пузыре', () {
    late String messageSource;

    setUp(() {
      final file = File('lib/pages/chat/events/message.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'Тест должен запускаться из clients/flutter/',
      );
      // Пробелы схлопываем: гейт разбит переносами строк форматтером, и
      // сравнивать надо форму условия, а не раскладку.
      messageSource = file.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
    });

    test('плашка строится только в канале с привязанным чатом', () {
      // Плашка переехала из ленты (chat_event_list) ВНУТРЬ пузыря поста: до
      // этого она рисовалась снаружи Message и уезжала влево за границу поста.
      // Гейт при переезде сохранил ту же конъюнкцию, только `controller.room`
      // сменился на `event.room`, а `isChannel` — на объемлющий isChannelPost.
      final listSource = File(
        'lib/pages/chat/chat_event_list.dart',
      ).readAsStringSync();
      expect(
        listSource.contains('ChannelPostComments('),
        isFalse,
        reason:
            'снаружи пузыря плашки быть не должно — ровно из-за этого она '
            'вылезала за границы поста',
      );

      var index = messageSource.indexOf('ChannelPostComments(');
      expect(
        index,
        isNot(-1),
        reason: 'плашка должна быть подключена в пузырь',
      );
      while (index != -1) {
        final windowStart = index - 300 < 0 ? 0 : index - 300;
        final window = messageSource.substring(windowStart, index);
        // Проверяем ТОЧНУЮ форму конъюнкции, а не наличие токенов: подстроки
        // `isChannelPost`/`hasComments` переживают инверсию гейта
        // (`!isChannelPost || hasComments || ...`), после которой плашка
        // протекает во все обычные чаты.
        expect(
          window.contains(
            'if (event.room.hasComments '
            '&& event.type == EventTypes.Message)',
          ),
          isTrue,
          reason:
              'плашка комментариев — только под сообщением с привязанным '
              'чатом, и только по конъюнкции обоих условий',
        );
        index = messageSource.indexOf('ChannelPostComments(', index + 1);
      }
    });

    test('низ поста канала целиком под гейтом isChannelPost', () {
      // Плашка и строка статистики собраны в ChannelPostFooter, а он строится
      // ровно в одном месте — под гейтом канала. Второй сайт использования или
      // потерянный гейт протащил бы низ поста в обычные чаты.
      // `&& !event.redacted` добавлен вместе с сокрытием удалённых постов
      // канала (ledger:RL-channel-redacted-post-hidden) — гейт УЖЕСТОЧЁН,
      // а не ослаблен: у надгробия не может быть ни реакций, ни плашки
      // комментариев.
      // dart format при глубоком отступе рвёт вызов в `isChannelPost( event, )`.
      expect(
        messageSource
            .replaceAll('isChannelPost( event, )', 'isChannelPost(event)')
            .contains(
              'if (isChannelPost(event) && !event.redacted) ChannelPostFooter(',
            ),
        isTrue,
        reason: 'низ поста канала обязан стоять под гейтом isChannelPost',
      );
      expect(
        RegExp(r'ChannelPostFooter\(').allMatches(messageSource).length,
        2,
        reason: 'ChannelPostFooter объявляется и используется ровно по разу',
      );
    });
  });

  group('подписка на таймлайн обсуждения', () {
    late String chatSource;
    late String barSource;

    setUp(() {
      final chatFile = File('lib/pages/chat/chat.dart');
      final barFile = File('lib/pages/chat/events/channel_post_comments.dart');
      expect(chatFile.existsSync(), isTrue);
      expect(barFile.existsSync(), isTrue);
      chatSource = chatFile.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      barSource = barFile.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
    });

    test('таймлайн обсуждения отписывается в dispose', () {
      final disposeIndex = chatSource.indexOf('void dispose()');
      expect(disposeIndex, isNot(-1));
      final disposeBody = chatSource.substring(
        disposeIndex,
        disposeIndex + 600,
      );
      expect(
        disposeBody.contains(
          'discussionTimeline?.cancelSubscriptions(); discussionTimeline = null;',
        ),
        isTrue,
        reason: 'иначе подписка на таймлайн чата-обсуждения течёт',
      );
    });

    test('лента не вступает в чат ради простого показа', () {
      // Тихий join — только по явному действию пользователя (тап по плашке),
      // а показ ленты обходится peek-таймлайном.
      final initIndex = chatSource.indexOf('void initState()');
      expect(initIndex, isNot(-1));
      final initBody = chatSource.substring(initIndex, initIndex + 3000);
      expect(
        initBody.contains('ensureDiscussionMembership'),
        isFalse,
        reason: 'вступление в чат при открытии канала — не наш сценарий',
      );
    });

    test('после тихого join состояние комментариев перечитывается', () {
      // Сценарий: не-член тапнул плашку -> тихий join -> оставил комментарий ->
      // вернулся в канал. Без перечитывания счётчик остался бы на мёртвом
      // снимке peek'а (ноль), потому что peek делается ровно один раз.
      // Метод переименован в _openThread (Этап 2): тап ведёт в тред поста,
      // а не в привязанный чат целиком. Инвариант «join -> перечитать»
      // от переименования не изменился.
      final openIndex = barSource.indexOf('Future<void> _openThread(');
      expect(openIndex, isNot(-1));
      // Окно расширено: между join и перечитыванием появилась ветка
      // различения исходов (ledger:RL-channel-discussion-federated-join) —
      // «join принят, но комната не приехала в sync» больше не выдаётся за
      // отказ в доступе. Порядок «join → перечитать» от этого не изменился.
      final openBody = barSource.substring(openIndex, openIndex + 1400);
      final joinIndex = openBody.indexOf('ensureDiscussionMembershipResult');
      final reloadIndex = openBody.indexOf('onMembershipGained()');
      expect(
        joinIndex,
        isNot(-1),
        reason: 'тап по плашке обязан обеспечивать членство',
      );
      expect(
        reloadIndex,
        isNot(-1),
        reason:
            'после тихого join состояние комментариев обязано перечитываться, '
            'иначе плашка навсегда застрянет на снимке peek',
      );
      expect(
        reloadIndex > joinIndex,
        isTrue,
        reason: 'перечитывать надо ПОСЛЕ join, иначе членства ещё нет',
      );
      // Колбэк должен быть заведён обязательным параметром и приходить из
      // контроллера — иначе «перезагрузка» будет заглушкой.
      expect(
        barSource.contains('required this.onMembershipGained'),
        isTrue,
        reason: 'колбэк перезагрузки — обязательный параметр плашки',
      );
      final listSource = File(
        'lib/pages/chat/chat_event_list.dart',
      ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      expect(
        listSource.contains(
          'onMembershipGained: controller.reloadDiscussionEvents',
        ),
        isTrue,
        reason:
            'плашка обязана дёргать перезагрузку контроллера, а не пустышку',
      );
    });

    test('перечитывание поднимает живой таймлайн вместо снимка peek', () {
      final reloadIndex = chatSource.indexOf(
        'Future<void> reloadDiscussionEvents()',
      );
      expect(
        reloadIndex,
        isNot(-1),
        reason: 'загрузка комментариев обязана быть повторно вызываемой',
      );
      final body = chatSource.substring(reloadIndex, reloadIndex + 1200);
      expect(
        body.contains('membership == Membership.join'),
        isTrue,
        reason: 'члену чата положен живой таймлайн, а не peek',
      );
      expect(
        body.contains('discussionTimeline?.cancelSubscriptions()'),
        isTrue,
        reason: 'старый таймлайн надо отменить перед заменой, иначе течёт',
      );
      // initState обязан звать именно перевызываемый метод — иначе повторный
      // вызов после join некому сделать.
      final initIndex = chatSource.indexOf('void initState()');
      final initBody = chatSource.substring(initIndex, initIndex + 3000);
      expect(initBody.contains('reloadDiscussionEvents()'), isTrue);
    });
  });
}
