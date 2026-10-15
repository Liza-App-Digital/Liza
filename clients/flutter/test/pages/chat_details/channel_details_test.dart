import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Экран деталей канала: созвон не показываем, настройки прав — только
// админам, обсуждение доступно ссылкой, канал можно удалить.
// Структурный тест: полноценный widget-тест экрана требует поднятого клиента
// с комнатой-каналом и всеми зависимостями Matrix.
//
// Проверки ниже матчат ТОЧНУЮ форму условия (гейта), а не отдельные токены:
// `view.contains('deleteChannelAction')` остаётся true при любой инверсии
// условия над этой веткой — токен просто стоит внутри if с любым условием.
// Инверсия (`&&` → нет, `>=` → `<`, `!` снят) — единственная диверсия, которая
// правда опасна (даёт доступ к необратимому действию не тем, кому положено),
// и именно её нужно ловить целиком, посимвольно.

/// Убирает пробелы/переносы строк, чтобы сравнение не было хрупким
/// к переформатированию (`dart format`), но оставалось точным к самому
/// условию: инверсия `&&`/`<`/`!` меняет строку даже после нормализации.
String _normalize(String source) =>
    source.replaceAll(RegExp(r'\s+'), ' ').trim();

void main() {
  group('детали канала', () {
    late String view;
    late String controller;
    late String viewNormalized;

    setUp(() {
      final viewFile = File('lib/pages/chat_details/chat_details_view.dart');
      final controllerFile = File('lib/pages/chat_details/chat_details.dart');
      expect(
        viewFile.existsSync() && controllerFile.existsSync(),
        isTrue,
        reason: 'Тест должен запускаться из clients/flutter/',
      );
      view = viewFile.readAsStringSync();
      controller = controllerFile.readAsStringSync();
      viewNormalized = _normalize(view);
    });

    test('ссылка на созвон скрыта для канала', () {
      expect(
        view.contains('!room.isChannel'),
        isTrue,
        reason: 'секция созвона должна гейтиться по !room.isChannel',
      );
      // Точная форма гейта вместе со следующей строкой (началом виджета
      // созвона) — чтобы инверсия `if (!room.isChannel)` → `if (room.isChannel)`
      // не проходила молча: токен `!room.isChannel` от неё не зависит,
      // он живёт и в canEditChannelSettings.
      expect(
        viewNormalized.contains(
          _normalize('if (!room.isChannel) _CallLinkSectionWrapper('),
        ),
        isTrue,
        reason:
            'секция созвона должна начинаться сразу за `if (!room.isChannel)`',
      );
    });

    test('есть переход в привязанный чат', () {
      expect(controller.contains('openDiscussionAction'), isTrue);
      expect(view.contains('openDiscussionAction'), isTrue);
      // Пункт «Обсуждение» доступен только для канала с включёнными
      // комментариями: гейт должен требовать И isChannel, И hasComments, а не
      // любое из двух. Матчим точную форму условия целиком (не отдельные
      // токены, которые остаются в файле при любой перестановке/инверсии).
      final discussionBlockStart = view.indexOf(
        'onTap: controller.openDiscussionAction',
      );
      expect(
        discussionBlockStart,
        greaterThan(-1),
        reason: 'не найден onTap пункта перехода в обсуждение',
      );
      final ifStart = view.lastIndexOf('if (', discussionBlockStart);
      expect(
        ifStart,
        greaterThan(-1),
        reason: 'у пункта перехода в обсуждение должен быть предшествующий if',
      );
      final ifCondition = view.substring(ifStart, discussionBlockStart);
      expect(
        _normalize(
          ifCondition,
        ).startsWith(_normalize('if (room.isChannel && room.hasComments)')),
        isTrue,
        reason:
            'пункт «Обсуждение» должен гейтиться ровно по '
            'room.isChannel && room.hasComments',
      );
    });

    test('осознанный вход в обсуждение — через account data, не room-state', () {
      // Подписчик канала имеет PL=0, а у чата-обсуждения state_default:50,
      // поэтому запись room-state `com.liza.chat.topology` возвращала бы ему
      // M_FORBIDDEN и срывала переход. Признак «вступил осознанно» к тому же
      // индивидуален — room-state снял бы скрытость у всех сразу.
      final actionStart = controller.indexOf('void openDiscussionAction()');
      expect(
        actionStart,
        greaterThan(-1),
        reason: 'не найден openDiscussionAction',
      );
      // Границей метода берём начало следующего объявления в классе.
      final actionEnd = controller.indexOf('deleteChannelAction', actionStart);
      expect(actionEnd, greaterThan(actionStart));
      final body = _normalize(controller.substring(actionStart, actionEnd));

      expect(
        body.contains('chat.topology'),
        isFalse,
        reason: 'openDiscussionAction не должен трогать room-state топологии — '
            'подписчику с PL=0 сервер ответит M_FORBIDDEN',
      );
      expect(
        body.contains('setRoomStateWithKey'),
        isFalse,
        reason: 'осознанный вход не должен писать никакой room-state',
      );
      expect(
        body.contains('revealChatForMe()'),
        isTrue,
        reason: 'раскрытие должно идти через пер-юзерное revealChatForMe',
      );
      // Отказ второстепенных операций не должен срывать переход: и раскрытие,
      // и размьют обёрнуты каждый в свой try, а возврат id идёт после них.
      expect(
        body.contains(_normalize('try { await discussion.revealChatForMe();')),
        isTrue,
        reason: 'revealChatForMe должен быть обёрнут в try',
      );
      expect(
        body.contains(
          _normalize(
            'try { await discussion.setPushRuleState(PushRuleState.notify);',
          ),
        ),
        isTrue,
        reason: 'setPushRuleState должен быть обёрнут в try',
      );
      // Возврат — уже не голый id, а DiscussionJoinResult: вызывающему нужен
      // ещё и ИСХОД, чтобы отличить отказ сервера от таймаута sync
      // (ledger:RL-channel-discussion-federated-join). Комната достаётся из
      // него же, поэтому инвариант «после обоих try метод возвращает то, по
      // чему навигируют» сохранён.
      expect(
        body.contains(_normalize('return joinResult;')),
        isTrue,
        reason: 'метод обязан вернуть результат join для навигации',
      );
      expect(
        body.contains(_normalize('ensureDiscussionMembershipResult()')),
        isTrue,
        reason: 'исход join обязан доезжать до вызывающего: без него таймаут '
            'sync снова выглядел бы как «нет доступа»',
      );
    });

    test('раскрытие пишет room account data, а не state', () {
      final topology =
          File('lib/utils/chat_topology.dart').readAsStringSync();
      final normalized = _normalize(topology);
      // Точная форма вызова: подмена setAccountDataPerRoom на setAccountData
      // (глобальный, без roomId) или на setRoomStateWithKey сломала бы модель —
      // признак перестал бы быть привязанным к комнате либо стал общим.
      expect(
        normalized.contains(
          _normalize(
            'client.setAccountDataPerRoom( client.userID!, id, '
            'chatRevealedAccountDataType, {\'revealed\': true}, )',
          ),
        ),
        isTrue,
        reason: 'revealChatForMe должен писать room account data '
            'chatRevealedAccountDataType = {revealed: true}',
      );
      // Персональное раскрытие обязано ПЕРЕбивать room-state hidden:true,
      // то есть проверяться ДО чтения topology-стейта и возвращать false.
      expect(
        normalized.contains(_normalize('if (isRevealedByMe) return false;')),
        isTrue,
        reason: 'isHiddenChat должен возвращать false при персональном '
            'раскрытии — иначе кнопка «Обсуждение» ничего не покажет',
      );
      expect(
        normalized.indexOf('if (isRevealedByMe) return false;'),
        lessThan(normalized.indexOf('getState(_topologyEventType)')),
        reason: 'проверка раскрытия должна идти до чтения room-state',
      );
    });

    test('есть удаление канала', () {
      expect(controller.contains('deleteChannelAction'), isTrue);
      expect(view.contains('deleteChannelAction'), isTrue);
      // Пункт «Удалить канал» — необратимая по смыслу операция: гейт должен
      // требовать И isChannel, И права админа (>= adminPowerLevel = 99, с
      // 2026-10-14 владелец 100 / админ 99), а не любое из двух.
      // Матчим точную форму условия целиком (не отдельные токены), иначе
      // `room.isChannel` (без power level) тоже прошёл бы этот тест.
      final deleteBlockStart = view.indexOf(
        'onTap: controller.deleteChannelAction',
      );
      expect(
        deleteBlockStart,
        greaterThan(-1),
        reason: 'не найден onTap пункта удаления канала',
      );
      // Берём ближайший `if (` ПЕРЕД самой кнопкой удаления — это и есть её
      // гейт, независимо от того, сколько строк ListTile между ними.
      final ifStart = view.lastIndexOf('if (', deleteBlockStart);
      expect(
        ifStart,
        greaterThan(-1),
        reason: 'у пункта удаления канала должен быть предшествующий if',
      );
      final ifCondition = view.substring(ifStart, deleteBlockStart);
      expect(
        _normalize(ifCondition).startsWith(
          _normalize(
            'if (room.isChannel && room.ownPowerLevel >= adminPowerLevel)',
          ),
        ),
        isTrue,
        reason:
            'пункт «Удалить канал» должен гейтиться ровно по '
            'room.isChannel && room.ownPowerLevel >= adminPowerLevel',
      );
    });

    test('настройки прав гейтятся по power level', () {
      expect(
        view.contains('canEditChannelSettings'),
        isTrue,
        reason: 'настройки видимости/прав скрываются от гостей канала',
      );
      // Точная форма присваивания: инверсия `>=` → `<` меняет только
      // одну подстроку, а токен `canEditChannelSettings` остаётся в файле
      // при любом значении условия — его наличие ничего не гарантирует.
      expect(
        viewNormalized.contains(
          _normalize(
            'final canEditChannelSettings = !room.isChannel || room.ownPowerLevel >= adminPowerLevel;',
          ),
        ),
        isTrue,
        reason:
            'canEditChannelSettings должен быть '
            '!room.isChannel || room.ownPowerLevel >= adminPowerLevel дословно',
      );
    });

    test('заголовок экрана — «Детали канала» для канала', () {
      expect(
        view.contains('channelDetails'),
        isTrue,
        reason: 'AppBar должен показывать channelDetails при room.isChannel',
      );
      // Точная форма тернарника целиком: перестановка веток
      // (`room.isChannel ? chatDetails : channelDetails`) — то есть инверсия
      // гейта заголовка — не проходит молча, т.к. `channelDetails` тогда
      // стоит после `:`, а не сразу после `?`. Токен `channelDetails` сам по
      // себе остаётся в файле при любой перестановке, так что этот тест
      // ловит только удаление, а не инверсию — отдельно матчим форму.
      expect(
        viewNormalized.contains(
          _normalize(
            'room.isChannel ? L10n.of(context).channelDetails : L10n.of(context).chatDetails',
          ),
        ),
        isTrue,
        reason:
            'заголовок должен быть ровно '
            'room.isChannel ? channelDetails : chatDetails, не наоборот',
      );
    });
  });
}
