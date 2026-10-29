import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/message.dart';

// В канале аватарки «прочитал» заменяются счётчиком просмотров: подписчиков
// могут быть тысячи, кластер аватарок там бессмысленен.
// Сам виджет счётчика проверяем рендером; подмену аватарок на счётчик —
// структурно: сборка Event с полноценной Room требует поднятого клиента.

Future<void> _pump(WidgetTester tester, int count) async {
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
      home: Scaffold(body: ChannelViewCount(count: count)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('ChannelViewCount', () {
    testWidgets('показывает число просмотров', (tester) async {
      await _pump(tester, 42);
      expect(find.textContaining('42'), findsOneWidget);
    });

    testWidgets('ноль просмотров не рисуется', (tester) async {
      await _pump(tester, 0);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('рисует иконку просмотра', (tester) async {
      await _pump(tester, 7);
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    });

    testWidgets('русский plural: формы one/few/many', (tester) async {
      // Гейта на полноту intl_ru.arb нет — при отсутствии ключа во всех формах
      // Flutter молча подставит английский. Ловим это рендером.
      await _pump(tester, 1);
      expect(find.text('1 просмотр'), findsOneWidget);
      await _pump(tester, 3);
      expect(find.text('3 просмотра'), findsOneWidget);
      await _pump(tester, 12);
      expect(find.text('12 просмотров'), findsOneWidget);
    });
  });

  group('подмена аватарок счётчиком', () {
    late String source;

    setUp(() {
      final file = File('lib/pages/chat/events/message.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'Тест должен запускаться из clients/flutter/',
      );
      source = file.readAsStringSync();
    });

    test('счётчик стоит под гейтом канала, аватарки — ветка обычного чата', () {
      // Пробелы схлопываем: перенос строк ставит dart format, а не автор
      // (при глубоком отступе он рвёт и `seenByUsers .length`).
      final compact = source
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll(' .', '.');
      // Раньше это была одна тернарная развилка снаружи пузыря. Низ поста
      // канала переехал ВНУТРЬ пузыря (ChannelPostStatsRow), поэтому ветки
      // разъехались по разным поддеревьям — инвариант тот же, форма другая:
      // счётчик берёт seenByUsers.length под гейтом канала, а кластер аватарок
      // рисуется только когда пост НЕ канальный.
      expect(
        compact.contains('viewCount: seenByUsers.length'),
        isTrue,
        reason: 'счётчик просмотров по-прежнему считает границы прочтения',
      );
      // С заявки №60 кластер стоит СБОКУ от пузыря (BubbleReceiptsSide), а
      // гейт канала / Liza News вынесен в showSeenSlot — слота там нет вовсе.
      expect(
        compact.contains(
          'final showSeenSlot = !isChannelPost(event) && '
          '!event.room.hideReadReceipts;',
        ),
        isTrue,
        reason: 'в обычных чатах обязан остаться кластер SeenByAvatars',
      );
      expect(
        compact.contains('reserve: showSeenSlot,'),
        isTrue,
        reason: 'боковой слот аватарок подчиняется гейту канала',
      );
      expect(
        compact.contains(
          'SeenByAvatars( receipts: seenByUsers, maxWidth: maxWidth, )',
        ),
        isTrue,
        reason: 'кластер аватарок никуда не делся из обычных чатов',
      );
    });

    test('внешний блок реакций погашен для поста канала', () {
      // Симметрично гейту SeenByAvatars выше. Реакции у поста канала рисует
      // ChannelPostStatsRow ВНУТРИ пузыря; внешний блок обязан быть погашен,
      // иначе они задваиваются — ровно тот класс бага (низ поста из четырёх
      // независимых блоков), из-за которого кнопка комментариев и уезжала за
      // границы пузыря.
      final compact = source.replaceAll(RegExp(r'\s+'), ' ');
      final gateIndex = compact.indexOf(
        'if (!isChannelPost(event)) AnimatedSize(',
      );
      expect(
        gateIndex,
        isNot(-1),
        reason:
            'внешний AnimatedSize с реакциями обязан стоять под гейтом '
            '!isChannelPost — иначе у поста канала реакции рисуются дважды',
      );
      // Гейт должен накрывать именно блок с MessageReactions, а не какой-то
      // другой AnimatedSize (ниже по файлу есть блок тредов).
      expect(
        compact
            .substring(gateIndex, gateIndex + 400)
            .contains('MessageReactions(event, timeline)'),
        isTrue,
        reason: 'под гейтом должен быть именно блок реакций',
      );
      // Реакции строятся ровно дважды: внешний блок (обычные чаты) и
      // ChannelPostFooter (канал). Третий сайт обошёл бы один из гейтов.
      // В канале это `chipsFor` — строке статистики нужны чипы списком, а не
      // готовый Wrap (иначе полоса схлопывается в столбик).
      expect(
        RegExp(
          r'MessageReactions(\(event, timeline\)|\.chipsFor\(context, event, timeline\))',
        ).allMatches(compact).length,
        2,
        reason:
            'реакции строятся ровно в двух местах: внешний блок для обычных '
            'чатов и ChannelPostFooter для канала',
      );
    });

    test('время у поста канала рисуется ровно один раз', () {
      // Время в Message размещается ЧЕТЫРЬМЯ независимыми путями. У поста
      // канала его рисует только ChannelPostStatsRow, поэтому все четыре
      // обязаны быть погашены общим флагом. Раньше гасился лишь текстовый
      // путь, и пост с картинкой/голосовым/файлом/подписью показывал время
      // дважды (в случае belowFooter — двумя метками одна под другой).
      final compact = source.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        compact.contains('final timeInChannelStatsRow = isChannelPost(event)'),
        isTrue,
        reason: 'общий флаг подавления времени в посте канала',
      );
      // 1) текст. После выноса времени текста в правый нижний угол
      //    (RL-message-time-corner) inline-хвоста `trailingTextTimeSpan` больше
      //    нет — текст идёт тем же путём `trailingTime`, что и голос/файл,
      //    поэтому в канале его гасит ОБЩИЙ гейт contentPlacesTime, куда входит
      //    `rendersAsText`. Проверяем оба факта: старого пути нет, а rendersAsText
      //    сидит внутри выражения contentPlacesTime (то — под !timeInChannelStatsRow,
      //    проверка (2) ниже).
      // Проверяем ОБЪЯВЛЕНИЕ (не слово — оно ещё живёт в поясняющем комментарии):
      // отдельной переменной-спана времени текста больше нет.
      expect(
        compact.contains('final trailingTextTimeSpan ='),
        isFalse,
        reason:
            'inline-путь времени текста (trailingTextTimeSpan) удалён — время '
            'текста идёт через trailingTime/contentPlacesTime, отдельный '
            'механизм подавления не нужен и разъезжался бы с общим',
      );
      final cptStart = compact.indexOf('final contentPlacesTime =');
      final cptExpr = compact.substring(
        cptStart,
        compact.indexOf(';', cptStart),
      );
      expect(
        cptExpr.contains('rendersAsText'),
        isTrue,
        reason:
            'текст (rendersAsText) обязан входить в contentPlacesTime — так его '
            'время гасится в канале тем же гейтом !timeInChannelStatsRow',
      );
      // 2) trailingTime: голос/файл + оверлей на медиа
      expect(
        compact.contains('final contentPlacesTime = !timeInChannelStatsRow &&'),
        isTrue,
        reason:
            'голос/файл/оверлей на медиа обязаны гаситься в канале — иначе '
            'время задваивается на картинке и в голосовом',
      );
      // 3) отдельная строка справа под контентом
      expect(
        compact.contains('final belowFooter = !timeInChannelStatsRow &&'),
        isTrue,
        reason:
            'строка времени под контентом обязана гаситься в канале — иначе '
            'две метки встают одна под другой',
      );
      // 4) хвост подписи медиа (отдельный пузырь ниже основного)
      expect(
        compact.contains(
          'trailingSpan: timeInChannelStatsRow ? null : inlineTimeSpan',
        ),
        isTrue,
        reason: 'подпись медиа обязана гасить время в канале',
      );
    });

    test('ChannelViewCount не рисуется вне ветки isChannelPost', () {
      // Счётчик теперь инстанцируется внутри ChannelPostStatsRow, та — внутри
      // ChannelPostFooter, а он строится только под гейтом канала. Проверяем
      // всю цепочку: иначе счётчик протёк бы в обычные чаты через любое звено.
      // dart format при глубоком отступе рвёт вызов в `isChannelPost( event, )`
      // — схлопываем и это, чтобы проверять смысл, а не перенос строк.
      final compact = source
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll('isChannelPost( event, )', 'isChannelPost(event)');
      // `&& !event.redacted` добавлен вместе с сокрытием удалённых постов
      // канала (ledger:RL-channel-redacted-post-hidden) — гейт УЖЕСТОЧЁН,
      // а не ослаблен: у надгробия не может быть ни счётчика, ни реакций.
      expect(
        compact.contains(
          'if (isChannelPost(event) && !event.redacted) ChannelPostFooter(',
        ),
        isTrue,
        reason: 'низ поста канала — только под гейтом isChannelPost',
      );
      expect(
        RegExp(r'ChannelPostStatsRow\(').allMatches(compact).length,
        2,
        reason:
            'строка статистики объявляется и используется ровно по разу — '
            'второй сайт использования обошёл бы гейт канала',
      );

      // Каждый сайт инстанцирования счётчика обязан лежать в теле класса
      // ChannelPostStatsRow: ближайшее объявление класса ВЫШЕ по файлу — это
      // она. Вынести счётчик в любой другой виджет = обойти гейт канала.
      var index = source.indexOf('ChannelViewCount(count:');
      expect(index, isNot(-1));
      while (index != -1) {
        final classesAbove = RegExp(
          r'^class (\w+)',
          multiLine: true,
        ).allMatches(source.substring(0, index)).toList();
        expect(
          classesAbove.last.group(1),
          'ChannelPostStatsRow',
          reason:
              'счётчик просмотров живёт только внутри ChannelPostStatsRow, '
              'которая сама под гейтом канала',
        );
        index = source.indexOf('ChannelViewCount(count:', index + 1);
      }
    });
  });
}
