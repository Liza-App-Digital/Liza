import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Лента канала выглядит одинаково для всех, как в Liza: пост админа НЕ
// рисуется «своим» (справа, другим цветом, с галочками доставки) — иначе автор
// видит собственную ленту зеркальной относительно подписчиков.
//
// Реализовано одним гейтом в точке вычисления `ownMessage`: этот флаг управляет
// ~20 решениями отрисовки (alignment, цвета, скругления, showStatus, отступы
// реакций и квитанций), и подменять их поимённо — путь к рассинхрону.
//
// Структурный тест: сборка Event с полноценной Room в unit-тесте требует
// поднятого клиента, поэтому проверяем инвариант в коде отрисовки — как в
// channel_attribution_test.dart.

void main() {
  group('единообразие постов в канале', () {
    late String source;
    late String compact;

    setUp(() {
      final file = File('lib/pages/chat/events/message.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'Тест должен запускаться из clients/flutter/',
      );
      source = file.readAsStringSync();
      // Пробелы схлопываем: перенос строк ставит dart format, а не автор.
      compact = source.replaceAll(RegExp(r'\s+'), ' ');
    });

    test('ownMessage вычисляется ровно один раз', () {
      // Гейт держится на единственности точки вычисления: появится второе
      // присваивание без гейта — часть отрисовки снова разъедется.
      expect(
        RegExp(r'\bownMessage\s*=').allMatches(compact).length,
        1,
        reason: 'подмена должна быть в одном месте, а не размазана по build()',
      );
    });

    test('в канале ownMessage сбрасывается в false', () {
      expect(
        compact.contains(
          'final ownMessage = event.senderId == client.userID && '
          '!isChannelPost(event)',
        ),
        isTrue,
        reason:
            'пост канала не считается «своим» при отрисовке: слева, единым '
            'цветом, без галочек',
      );
    });

    test('подмена стоит под гейтом канала, а не глобально', () {
      // Страховка обычных чатов: без isChannelPost в этой строке свои
      // сообщения в личках/группах перестанут выравниваться вправо.
      final line = source
          .split('\n')
          .firstWhere((l) => RegExp(r'\bownMessage\s*=').hasMatch(l));
      expect(
        line.contains('isChannelPost(event)'),
        isTrue,
        reason: 'гейт канала обязан быть в той же строке, что и вычисление',
      );
      expect(
        line.contains('event.senderId == client.userID'),
        isTrue,
        reason: 'вне канала ownMessage по-прежнему = авторство события',
      );
    });

    test('решения отрисовки идут через ownMessage, а не через senderId', () {
      // Единственность гейта работает, только пока сравнение с client.userID
      // нигде не продублировано: обход подмены вернёт автору «зеркальную»
      // ленту, и структурные проверки выше этого не заметят.
      expect(
        RegExp(r'senderId\s*==\s*client\.userID').allMatches(compact).length,
        1,
        reason: 'авторство сравнивается ровно в одной точке — в гейте',
      );
      expect(
        compact.contains('client.userID ==') ||
            compact.contains('userID == event.senderId'),
        isFalse,
        reason: 'обратный порядок сравнения — тот же обход гейта',
      );
    });

    test('ключевые render-сайты остались завязаны на ownMessage', () {
      // Если решение отрисовки увести с ownMessage на что-то другое, канал
      // снова разъедется, а гейт формально останется на месте.
      final renderSites = <String, String>{
        'alignment = ownMessage ? Alignment.topRight': 'выравнивание пузыря',
        'ownMessage ? MainAxisAlignment.end': 'сторона строки сообщения',
        'crossAxisAlignment: ownMessage ?': 'сторона колонки',
        'alignGutterToBubble: ownMessage': 'привязка жёлоба',
        'final textColor = ownMessage': 'цвет текста',
        'final linkColor = ownMessage': 'цвет ссылок',
      };
      renderSites.forEach((marker, what) {
        expect(
          compact.contains(marker),
          isTrue,
          reason: '$what должно идти от ownMessage ($marker)',
        );
      });
    });

    test('галочки статуса привязаны к ownMessage и гаснут в канале', () {
      expect(
        compact.contains('showStatus: ownMessage'),
        isTrue,
        reason:
            'индикатор доставки/прочтения идёт от подменяемого флага, значит '
            'в канале не показывается',
      );
      expect(
        compact.contains('if (ownMessage) { if (event.status =='),
        isTrue,
        reason: 'inline-иконка статуса тоже под ownMessage',
      );
    });

    test('цвет пузыря идёт от того же флага', () {
      expect(
        compact.contains('if (ownMessage) { color = displayEvent.status.isError'),
        isTrue,
        reason: 'в канале все посты получают единый нейтральный цвет пузыря',
      );
    });

    test('права на правку/удаление не завязаны на ownMessage в message.dart', () {
      // Ключевой инвариант правки: подменяется ТОЛЬКО отрисовка. Права живут в
      // chat.dart (canEditEvent/canRedactEvent) и считаются от event.senderId
      // напрямую, поэтому админ канала по-прежнему правит и удаляет свои посты.
      for (final marker in ['canEditEvent', 'canRedactEvent', 'canPinEvent']) {
        expect(
          source.contains(marker),
          isFalse,
          reason:
              '$marker не должен появиться в message.dart: иначе подмена '
              'ownMessage начнёт влиять на права',
        );
      }

      final chat = File('lib/pages/chat/chat.dart').readAsStringSync();
      final chatCompact = chat.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        chatCompact.contains(
          'bool canEditEvent(Event event) => !isArchived && '
          '!isFluidPageEvent(event) && '
          'event.status.isSent && '
          'currentRoomBundle.any((cl) => event.senderId == cl?.userID)',
        ),
        isTrue,
        reason: 'право на правку считается от senderId, без isChannelPost',
      );
      expect(
        chatCompact.contains('ownMessage: event.senderId == room.client.userID'),
        isTrue,
        reason:
            'контекстное меню получает НЕподменённое авторство из chat.dart, '
            'поэтому «пожаловаться» не появляется на собственном посте канала',
      );
    });
  });
}
