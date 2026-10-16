// ignore_for_file: depend_on_referenced_packages
//
// ledger:RL-channel-access-settings-layout
// ledger:RL-group-access-settings-layout
// ledger:RL-company-access-settings-toggle
// ledger:RL-channel-discussion-restricted-join
//
// AC-1..AC-5 — real-widget страж на ChatAccessSettingsPageView (реальный
//              прод-виджет через фейковый контроллер, перекрывающий room/
//              isChannel, чтобы не поднимать полный Matrix-стек и HTTP).
// AC-6      — source-scan страж на контроллере (паттерн принят в проекте:
//             см. chat_access_settings_controller_test.dart).
//
// Инварианты:
//   1. Публичный канал: раздел «Видимость истории» read-only (enabled==false).
//   2. Приватный канал: раздел «Видимость истории» enabled==true.
//   3. «Тип канала» стоит ВЫШЕ «Видимость истории» и «Кому вступать».
//   4. Публичный канал: groupValue == worldReadable — нет пустого радио.
//   5. Не-канал: блока «Тип канала» НЕТ, раздел видимости истории есть.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_access_settings/chat_access_settings_controller.dart';
import 'package:liza/pages/chat_access_settings/chat_access_settings_page.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

// ─── Фейковый MatrixState — подменяем только client-геттер ─────────────────
// Полноценный Matrix-виджет тяжёл (push/VoIP/connectivity).
class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
}

// ─── Фейковый контроллер ─────────────────────────────────────────────────────
// ChatAccessSettingsController extends State<>, поэтому в тесте его нельзя
// создать напрямую без виджета. Подкласс перекрывает room/isChannel (чтобы не
// вызывать Matrix.of(context).client.getRoomById) и no-op initState (чтобы не
// делать HTTP-запрос к auth-proxy за ником канала). isPublicChannel остаётся
// родительским — он читает room.joinRules, а room мы подменили.
class _FakeController extends ChatAccessSettingsController {
  _FakeController({required this.fakeRoom, required this.fakeIsChannel});

  final Room fakeRoom;
  final bool fakeIsChannel;

  @override
  Room get room => fakeRoom;

  @override
  bool get isChannel => fakeIsChannel;

  // super.initState() намеренно НЕ вызывается — пропускаем _loadChannelHandle
  // (HTTP к auth-proxy за ником канала), не нужный для проверки раскладки.
  @override
  // ignore: must_call_super
  void initState() {}
}

// view — это уже Scaffold с внутренним скроллом (MaxWidthBody.withScrolling).
// Оборачивать его в ещё один Scaffold+SingleChildScrollView НЕЛЬЗЯ: внешний
// скролл даёт Scaffold бесконечную высоту → assertion «infinite size». Кладём
// view как home напрямую — MaterialApp даёт ограниченные констрейнты экрана.
Widget _wrapView(ChatAccessSettingsPageView view, Client client) => MaterialApp(
  locale: const Locale('ru'),
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  home: Provider<liza_matrix.MatrixState>.value(
    value: _TestMatrixState(client),
    child: view,
  ),
);

Event _state(
  Room room,
  String type,
  Map<String, Object?> content, {
  String stateKey = '',
  int ts = 1000,
}) => Event(
  eventId: '\$$type$ts',
  senderId: '@owner:example.invalid',
  originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
  type: type,
  content: content,
  room: room,
  stateKey: stateKey,
);

/// Комната-канал. join_rules публичный/приватный, history_visibility задана.
Room _makeChannelRoom(
  Client client, {
  JoinRules joinRules = JoinRules.public,
  HistoryVisibility historyVisibility = HistoryVisibility.worldReadable,
}) {
  final room = Room(id: '!channel:example.invalid', client: client);
  room.setState(
    _state(room, EventTypes.RoomCreate, {
      'com.liza.chat.type': channelChatType,
    }, ts: 1000),
  );
  room.setState(
    _state(room, EventTypes.RoomJoinRules, {
      'join_rule': joinRules.text,
    }, ts: 1001),
  );
  room.setState(
    _state(room, EventTypes.HistoryVisibility, {
      'history_visibility': historyVisibility.text,
    }, ts: 1002),
  );
  room.setState(
    _state(room, EventTypes.RoomPowerLevels, {
      'state_default': 50,
      'events_default': 0,
      'users_default': 0,
      'users': {'@alice:example.invalid': 100},
    }, ts: 1003),
  );
  room.setState(
    _state(
      room,
      EventTypes.RoomMember,
      {'membership': 'join', 'displayname': 'Alice'},
      stateKey: '@alice:example.invalid',
      ts: 1004,
    ),
  );
  return room;
}

/// Обычная группа (не канал). [joinRule] задаёт join_rules, [chatType] —
/// значение `com.liza.chat.type` в RoomCreate (для channel_discussion).
Room _makeGroupRoom(
  Client client, {
  JoinRules joinRule = JoinRules.invite,
  String? chatType,
  bool selfAdmin = true,
}) {
  final room = Room(id: '!group:example.invalid', client: client);
  room.setState(
    _state(room, EventTypes.RoomCreate, {
      if (chatType != null) 'com.liza.chat.type': chatType,
    }, ts: 1000),
  );
  room.setState(
    _state(room, EventTypes.RoomJoinRules, {
      'join_rule': joinRule.text,
    }, ts: 1001),
  );
  room.setState(
    _state(room, EventTypes.HistoryVisibility, {
      'history_visibility': 'shared',
    }, ts: 1002),
  );
  room.setState(
    _state(room, EventTypes.RoomPowerLevels, {
      'state_default': 50,
      'events_default': 0,
      'users_default': 0,
      // selfAdmin → ТЕКУЩЕМУ пользователю (client.userID) PL 100, иначе он не в
      // users → PL 0 (users_default), state_default 50 недостижим →
      // canChangeJoinRules=false. Ключ — именно userID клиента, не литерал.
      'users': selfAdmin
          ? {client.userID!: 100}
          : <String, int>{'@owner:example.invalid': 100},
    }, ts: 1003),
  );
  return room;
}

/// Пространство-компания (top-level space). [domain] задаёт домен roomId: по
/// умолчанию совпадает с доменом client.userID (@alice:example.invalid) →
/// foreignCompanyKind==own. Другой домен → foreign (чужая компания).
Room _makeCompanyRoom(
  Client client, {
  JoinRules joinRule = JoinRules.invite,
  bool selfAdmin = true,
  String? domain,
}) {
  // По умолчанию домен roomId = домен client.userID → foreignCompanyKind==own.
  // Тестовый client логинится как @test:fakeServer.notExisting, поэтому берём
  // домен из client, а не литерал.
  final d = domain ?? client.userID!.domain!;
  final room = Room(id: '!company:$d', client: client);
  room.setState(
    _state(room, EventTypes.RoomCreate, {'type': 'm.space'}, ts: 1000),
  );
  room.setState(
    _state(room, EventTypes.RoomJoinRules, {
      'join_rule': joinRule.text,
    }, ts: 1001),
  );
  room.setState(
    _state(room, EventTypes.RoomPowerLevels, {
      'state_default': 50,
      'events_default': 100,
      'users_default': 0,
      'users': selfAdmin
          ? {client.userID!: 100}
          : <String, int>{'@owner:example.invalid': 100},
    }, ts: 1003),
  );
  return room;
}

ChatAccessSettingsPageView _viewForRoom(Room room, {required bool isChannel}) =>
    ChatAccessSettingsPageView(
      _FakeController(fakeRoom: room, fakeIsChannel: isChannel),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  late Client client;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  // AC:RL-channel-access-settings-layout/1
  testWidgets(
    'AC-1: публичный канал — раздел «Видимость истории» read-only (все enabled==false)',
    (tester) async {
      final room = _makeChannelRoom(
        client,
        joinRules: JoinRules.public,
        historyVisibility: HistoryVisibility.worldReadable,
      );
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: true), client),
      );
      await _settle(tester);

      expect(
        find.text('Видимость истории канала'),
        findsOneWidget,
        reason:
            'Раздел видимости истории должен отображаться для публичного канала',
      );

      final tiles = tester
          .widgetList<RadioListTile<HistoryVisibility>>(
            find.byType(RadioListTile<HistoryVisibility>),
          )
          .toList();

      expect(
        tiles.length,
        equals(HistoryVisibility.values.length),
        reason: 'Ровно ${HistoryVisibility.values.length} плитки видимости',
      );
      for (final tile in tiles) {
        expect(
          tile.enabled,
          isFalse,
          reason:
              'RadioListTile ${tile.value} должна быть enabled==false в публичном канале',
        );
      }
    },
  );

  // AC:RL-channel-access-settings-layout/2
  testWidgets(
    'AC-2: приватный канал — раздел «Видимость истории» enabled (все enabled==true)',
    (tester) async {
      final room = _makeChannelRoom(
        client,
        joinRules: JoinRules.invite,
        historyVisibility: HistoryVisibility.shared,
      );
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: true), client),
      );
      await _settle(tester);

      final tiles = tester
          .widgetList<RadioListTile<HistoryVisibility>>(
            find.byType(RadioListTile<HistoryVisibility>),
          )
          .toList();

      expect(tiles.isNotEmpty, isTrue);
      for (final tile in tiles) {
        expect(
          tile.enabled,
          isTrue,
          reason:
              'RadioListTile ${tile.value} должна быть enabled==true в приватном канале',
        );
      }
    },
  );

  // AC:RL-channel-access-settings-layout/3
  testWidgets(
    'AC-3: «Тип канала» выше «Видимость истории» и «Кому вступать» — публичный канал',
    (tester) async {
      final room = _makeChannelRoom(client, joinRules: JoinRules.public);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: true), client),
      );
      await _settle(tester);

      final channelTypeTitle = find.text('Тип канала');
      final historyTitle = find.text('Видимость истории канала');
      final joinTitle = find.text('Кому разрешено вступать в этот канал');

      expect(channelTypeTitle, findsOneWidget);
      expect(historyTitle, findsOneWidget);
      expect(joinTitle, findsOneWidget);

      final channelTypeY = tester.getTopLeft(channelTypeTitle).dy;
      final historyY = tester.getTopLeft(historyTitle).dy;
      final joinY = tester.getTopLeft(joinTitle).dy;

      expect(
        channelTypeY,
        lessThan(historyY),
        reason:
            '"Тип канала" (y=$channelTypeY) должен быть ВЫШЕ "Видимость истории" (y=$historyY)',
      );
      expect(
        channelTypeY,
        lessThan(joinY),
        reason:
            '"Тип канала" (y=$channelTypeY) должен быть ВЫШЕ "Кому вступать" (y=$joinY)',
      );
    },
  );

  // AC:RL-channel-access-settings-layout/3 (приватный)
  testWidgets(
    'AC-3: «Тип канала» выше «Видимость истории канала» — приватный канал',
    (tester) async {
      final room = _makeChannelRoom(client, joinRules: JoinRules.invite);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: true), client),
      );
      await _settle(tester);

      final channelTypeY = tester.getTopLeft(find.text('Тип канала')).dy;
      final historyY = tester
          .getTopLeft(find.text('Видимость истории канала'))
          .dy;
      expect(
        channelTypeY,
        lessThan(historyY),
        reason:
            '"Тип канала" должен быть выше "Видимость истории" в приватном канале',
      );
    },
  );

  // AC:RL-channel-access-settings-layout/4
  testWidgets(
    'AC-4: публичный канал — groupValue==worldReadable, ровно одна плитка совпадает (нет пустого радио)',
    (tester) async {
      final room = _makeChannelRoom(
        client,
        joinRules: JoinRules.public,
        historyVisibility: HistoryVisibility.worldReadable,
      );
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: true), client),
      );
      await _settle(tester);

      final tiles = tester
          .widgetList<RadioListTile<HistoryVisibility>>(
            find.byType(RadioListTile<HistoryVisibility>),
          )
          .toList();

      final matching = tiles.where((t) => t.value == room.historyVisibility);
      expect(
        matching.length,
        equals(1),
        reason:
            'Ровно одна RadioListTile должна иметь value==room.historyVisibility (нет пустого радио)',
      );
      expect(room.historyVisibility, equals(HistoryVisibility.worldReadable));
    },
  );

  // AC:RL-channel-access-settings-layout/5
  testWidgets(
    'AC-5: не-канал — «Тип канала» отсутствует, «Видимость истории чата» присутствует',
    (tester) async {
      final room = _makeGroupRoom(client);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      expect(
        find.text('Тип канала'),
        findsNothing,
        reason: 'Блок «Тип канала» не должен отображаться для не-канала',
      );
      expect(
        find.text('Видимость истории чата'),
        findsOneWidget,
        reason:
            'Раздел «Видимость истории чата» должен присутствовать для обычной группы',
      );
      // Взаимоисключение блоков: у группы есть «Тип группы», но НЕТ «Тип канала».
      expect(
        find.text('Тип группы'),
        findsOneWidget,
        reason: 'У обычной группы должен быть блок «Тип группы»',
      );
    },
  );

  // AC:RL-channel-access-settings-layout/5 (встречный: канал не имеет блока группы)
  // AC:RL-group-access-settings-layout/2 (взаимоисключение: канал без блока группы)
  testWidgets(
    'AC-5: канал — «Тип канала» есть, «Тип группы» отсутствует (взаимоисключение)',
    (tester) async {
      final room = _makeChannelRoom(client, joinRules: JoinRules.public);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: true), client),
      );
      await _settle(tester);

      expect(find.text('Тип канала'), findsOneWidget);
      expect(
        find.text('Тип группы'),
        findsNothing,
        reason: 'Блок «Тип группы» не должен протечь в канал',
      );
    },
  );

  // ─── RL-group-access-settings-layout ──────────────────────────────────────

  // AC:RL-group-access-settings-layout/1
  testWidgets(
    'AC-1(group): обычная группа (invite) — блок «Тип группы» присутствует, '
    'SegmentedButton показывает «Частная»',
    (tester) async {
      final room = _makeGroupRoom(client, joinRule: JoinRules.invite);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      expect(find.text('Тип группы'), findsOneWidget);
      final btn = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>),
      );
      expect(
        btn.selected,
        equals({false}),
        reason: 'join_rule invite → приватная группа',
      );
    },
  );

  // AC:RL-group-access-settings-layout/1
  testWidgets(
    'AC-1(group): публичная группа (public) — SegmentedButton показывает «Публичная»',
    (tester) async {
      final room = _makeGroupRoom(client, joinRule: JoinRules.public);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      final btn = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>),
      );
      expect(
        btn.selected,
        equals({true}),
        reason: 'join_rule public → публичная группа',
      );
    },
  );

  // AC:RL-group-access-settings-layout/3
  testWidgets('AC-3(group): channel_discussion — блока «Тип группы» НЕТ', (
    tester,
  ) async {
    final room = _makeGroupRoom(
      client,
      joinRule: JoinRules.invite,
      chatType: channelDiscussionChatType,
    );
    await tester.pumpWidget(
      _wrapView(_viewForRoom(room, isChannel: false), client),
    );
    await _settle(tester);

    expect(
      find.text('Тип группы'),
      findsNothing,
      reason: 'Обсуждение канала — не обычная группа, тумблера быть не должно',
    );
  });

  // AC:RL-channel-discussion-restricted-join/7
  testWidgets(
    'чат обсуждения: выбора «Кому разрешено вступать» НЕТ (правило ведёт сервер)',
    (tester) async {
      for (final jr in [
        JoinRules.restricted,
        JoinRules.invite,
        JoinRules.public,
      ]) {
        final room = _makeGroupRoom(
          client,
          joinRule: jr,
          chatType: channelDiscussionChatType,
        );
        await tester.pumpWidget(
          _wrapView(_viewForRoom(room, isChannel: false), client),
        );
        await _settle(tester);

        expect(
          find.text('Кому разрешено вступать в эту группу'),
          findsNothing,
          reason: '$jr: radio записал бы allow без канала и закрыл вход',
        );
        expect(
          find.byType(RadioListTile<JoinRules>),
          findsNothing,
          reason: '$jr',
        );
      }
      // Контроль: у обычной группы выбор на месте.
      final group = _makeGroupRoom(client, joinRule: JoinRules.invite);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(group, isChannel: false), client),
      );
      await _settle(tester);
      expect(find.text('Кому разрешено вступать в эту группу'), findsOneWidget);
    },
  );

  // AC:RL-group-access-settings-layout/4
  testWidgets(
    'AC-4(group): «Тип группы» выше «Видимость истории чата» и «Кому вступать»',
    (tester) async {
      final room = _makeGroupRoom(client, joinRule: JoinRules.invite);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      final groupTypeY = tester.getTopLeft(find.text('Тип группы')).dy;
      final historyY = tester
          .getTopLeft(find.text('Видимость истории чата'))
          .dy;
      final joinY = tester
          .getTopLeft(find.text('Кому разрешено вступать в эту группу'))
          .dy;
      expect(
        groupTypeY,
        lessThan(historyY),
        reason: '"Тип группы" должен быть выше "Видимость истории чата"',
      );
      expect(
        groupTypeY,
        lessThan(joinY),
        reason: '"Тип группы" должен быть выше "Кому вступать"',
      );
    },
  );

  // AC:RL-group-access-settings-layout/6
  testWidgets(
    'AC-6(group): видимость истории редактируема в ОБОИХ режимах группы '
    '(в отличие от публичного канала)',
    (tester) async {
      for (final jr in [JoinRules.public, JoinRules.invite]) {
        final room = _makeGroupRoom(client, joinRule: jr);
        await tester.pumpWidget(
          _wrapView(_viewForRoom(room, isChannel: false), client),
        );
        await _settle(tester);

        final tiles = tester
            .widgetList<RadioListTile<HistoryVisibility>>(
              find.byType(RadioListTile<HistoryVisibility>),
            )
            .toList();
        expect(tiles.isNotEmpty, isTrue);
        for (final tile in tiles) {
          expect(
            tile.enabled,
            isTrue,
            reason: 'История группы (join_rule=$jr) должна быть редактируема',
          );
        }
      }
    },
  );

  // AC:RL-group-access-settings-layout/7
  testWidgets(
    'AC-7(group): при join_rule knock тумблер «Тип группы» СКРЫТ, сырой radio есть',
    (tester) async {
      final room = _makeGroupRoom(client, joinRule: JoinRules.knock);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      expect(
        find.text('Тип группы'),
        findsNothing,
        reason:
            'knock — не бинарное состояние; тумблер не должен врать «Частная»',
      );
      // Сырой radio join_rules остаётся единственным контролом.
      expect(
        find.byType(RadioListTile<JoinRules>),
        findsWidgets,
        reason: 'radio join_rules должен присутствовать при knock',
      );
    },
  );

  // AC:RL-group-access-settings-layout/8
  testWidgets(
    'AC-8(group): участник без права смены join_rules (PL 0) — тумблер '
    '«Тип группы» неактивен (onSelectionChanged == null)',
    (tester) async {
      final room = _makeGroupRoom(
        client,
        joinRule: JoinRules.invite,
        selfAdmin: false,
      );
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      // Блок присутствует (гейт видимости не зависит от PL), но disabled.
      expect(find.text('Тип группы'), findsOneWidget);
      final btn = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>),
      );
      expect(
        btn.onSelectionChanged,
        isNull,
        reason:
            'PL 0 (canChangeJoinRules=false) → тумблер обязан быть '
            'неактивен, иначе UI обещает недоступное действие (M_FORBIDDEN)',
      );
    },
  );

  // AC:RL-group-access-settings-layout/8 (позитив: админ — тумблер активен)
  testWidgets(
    'AC-8(group): админ группы (PL 100) — тумблер «Тип группы» активен',
    (tester) async {
      final room = _makeGroupRoom(
        client,
        joinRule: JoinRules.invite,
        selfAdmin: true,
      );
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      final btn = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>),
      );
      expect(
        btn.onSelectionChanged,
        isNotNull,
        reason: 'админ (canChangeJoinRules=true) → тумблер активен',
      );
    },
  );

  // AC:RL-group-access-settings-layout/5
  test(
    'AC-5(group): setGroupPublic НЕ вызывает setHistoryVisibility/worldReadable '
    '(privacy — у группы нет peek-ленты)',
    () {
      const path =
          'lib/pages/chat_access_settings/chat_access_settings_controller.dart';
      final source = File(path).readAsStringSync();

      final start = source.indexOf('Future<void> setGroupPublic');
      expect(
        start,
        greaterThan(-1),
        reason: 'Метод setGroupPublic обязан существовать',
      );

      // Границы тела метода.
      final bodyStart = source.indexOf('{', start);
      var depth = 0;
      var bodyEnd = -1;
      for (var i = bodyStart; i < source.length; i++) {
        if (source[i] == '{') depth++;
        if (source[i] == '}') {
          depth--;
          if (depth == 0) {
            bodyEnd = i;
            break;
          }
        }
      }
      expect(bodyEnd, greaterThan(-1));
      final body = source.substring(bodyStart, bodyEnd);

      expect(
        body.contains('setHistoryVisibility'),
        isFalse,
        reason: 'setGroupPublic не должен трогать видимость истории',
      );
      expect(
        body.contains('worldReadable'),
        isFalse,
        reason:
            'публичная группа НЕ world_readable — иначе история читается '
            'анонимно (privacy-дыра)',
      );
      // Должен писать join_rules + directory.
      expect(body.contains('setJoinRules'), isTrue);
      expect(body.contains('setRoomVisibilityOnDirectory'), isTrue);
    },
  );

  // AC:RL-group-access-settings-layout/7 (source-scan гейта видимости тумблера)
  test('AC-7(group): showGroupTypeToggle исключает канал/обсуждение/личку/'
      'пространство и не-бинарные join_rules', () {
    const path =
        'lib/pages/chat_access_settings/chat_access_settings_controller.dart';
    final source = File(path).readAsStringSync();
    final start = source.indexOf('get showGroupTypeToggle');
    expect(start, greaterThan(-1));
    final body = source.substring(start, source.indexOf(';', start));
    expect(body.contains('!isChannel'), isTrue);
    expect(body.contains('isChannelDiscussion'), isTrue);
    expect(body.contains('isDirectChat'), isTrue);
    expect(body.contains('isSpace'), isTrue);
    expect(body.contains('JoinRules.public'), isTrue);
    expect(body.contains('JoinRules.invite'), isTrue);
  });

  // AC:RL-channel-access-settings-layout/6
  test('AC-6: setChannelPublic(true) форсит setHistoryVisibility(worldReadable) в ветке makePublic; '
      'вне неё вызова нет', () {
    const path =
        'lib/pages/chat_access_settings/chat_access_settings_controller.dart';
    final source = File(path).readAsStringSync();

    expect(
      source,
      contains('setChannelPublic'),
      reason: 'Метод setChannelPublic обязан существовать',
    );
    expect(
      source,
      contains('HistoryVisibility.worldReadable'),
      reason:
          'setChannelPublic(true) обязан форсить world_readable — иначе рвётся peek-лента',
    );

    final methodStart = source.indexOf('setChannelPublic');
    final makePublicIfIdx = source.indexOf('if (makePublic)', methodStart);
    expect(
      makePublicIfIdx,
      greaterThan(-1),
      reason: 'Блок if (makePublic) должен присутствовать в setChannelPublic',
    );

    final setHistoryIdx = source.indexOf(
      'setHistoryVisibility',
      makePublicIfIdx,
    );
    expect(
      setHistoryIdx,
      greaterThan(makePublicIfIdx),
      reason:
          'setHistoryVisibility вызывается внутри if (makePublic) — только при makePublic==true',
    );

    // Не должно быть ВТОРОГО вызова setHistoryVisibility внутри метода
    // (иначе — вызов и в false-ветке = утечка world_readable в приватный).
    final methodBodyStart = source.indexOf('{', methodStart);
    var depth = 0;
    var methodBodyEnd = -1;
    for (var i = methodBodyStart; i < source.length; i++) {
      if (source[i] == '{') {
        depth++;
      } else if (source[i] == '}') {
        depth--;
        if (depth == 0) {
          methodBodyEnd = i;
          break;
        }
      }
    }
    expect(methodBodyEnd, greaterThan(-1));

    final secondSetHistoryIdx = source.indexOf(
      'setHistoryVisibility',
      setHistoryIdx + 1,
    );
    if (secondSetHistoryIdx != -1 && secondSetHistoryIdx < methodBodyEnd) {
      fail(
        'setHistoryVisibility вызывается ДВАЖДЫ внутри setChannelPublic — '
        'это утечка world_readable в приватный канал',
      );
    }
  });

  // AC:RL-channel-access-settings-layout/7
  test('AC-7: setChannelPublic откатывает публичность при сбое (не оставляет '
      'public без world_readable)', () {
    // AC:RL-channel-access-settings-layout/7
    // Инвариант «публичный ⇒ world_readable» держится и при частичном сбое:
    // если setHistoryVisibility(worldReadable) упал после setJoinRules(public),
    // канал ОБЯЗАН откатиться в invite (иначе public без world_readable рвёт
    // peek-ленту, а вернуть world_readable из read-only-UI нельзя).
    const path =
        'lib/pages/chat_access_settings/chat_access_settings_controller.dart';
    final source = File(path).readAsStringSync();

    final methodStart = source.indexOf('setChannelPublic');
    final makePublicIfIdx = source.indexOf('if (makePublic)', methodStart);
    final setHistoryIdx = source.indexOf(
      'setHistoryVisibility',
      makePublicIfIdx,
    );

    // После форса world_readable должен идти rethrow-откат в invite (catch).
    final rollbackIdx = source.indexOf('JoinRules.invite', makePublicIfIdx);
    final rethrowIdx = source.indexOf('rethrow', makePublicIfIdx);

    expect(
      rollbackIdx,
      greaterThan(setHistoryIdx),
      reason:
          'После setHistoryVisibility(worldReadable) в ветке makePublic должен '
          'быть откат setJoinRules(JoinRules.invite) на случай сбоя',
    );
    expect(
      rethrowIdx,
      greaterThan(setHistoryIdx),
      reason: 'Откат должен пробрасывать ошибку (rethrow), а не глотать её',
    );
  });

  // ─── RL-company-access-settings-toggle ────────────────────────────────────

  // AC:RL-company-access-settings-toggle/1
  testWidgets(
    'AC-1(company): своя компания (invite) — блок «Тип компании» есть, '
    'SegmentedButton показывает «Частная»',
    (tester) async {
      final room = _makeCompanyRoom(client, joinRule: JoinRules.invite);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      expect(find.text('Тип компании'), findsOneWidget);
      final btn = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>),
      );
      expect(
        btn.selected,
        equals({false}),
        reason: 'join_rule invite → частная компания',
      );
    },
  );

  // AC:RL-company-access-settings-toggle/1
  testWidgets(
    'AC-1(company): публичная компания (public) — SegmentedButton «Публичная»',
    (tester) async {
      final room = _makeCompanyRoom(client, joinRule: JoinRules.public);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      final btn = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>),
      );
      expect(
        btn.selected,
        equals({true}),
        reason: 'join_rule public → публичная компания',
      );
    },
  );

  // AC:RL-company-access-settings-toggle/2
  testWidgets(
    'AC-2(company): суб-пространство (есть родитель-space) — блока «Тип '
    'компании» НЕТ',
    (tester) async {
      final sub = _makeCompanyRoom(client, joinRule: JoinRules.invite);
      // Родитель-space с m.space.child → sub перестаёт быть top-level.
      final parent = Room(id: '!parent:example.invalid', client: client);
      parent.setState(
        _state(parent, EventTypes.RoomCreate, {'type': 'm.space'}, ts: 900),
      );
      parent.setState(
        _state(
          parent,
          'm.space.child',
          {
            'via': <String>['example.invalid'],
          },
          stateKey: sub.id,
          ts: 901,
        ),
      );
      client.rooms.add(parent);

      await tester.pumpWidget(
        _wrapView(_viewForRoom(sub, isChannel: false), client),
      );
      await _settle(tester);

      expect(
        find.text('Тип компании'),
        findsNothing,
        reason: 'у суб-пространства (не root-space) тумблера компании нет',
      );
    },
  );

  // AC:RL-company-access-settings-toggle/3
  testWidgets(
    'AC-3(company): чужая (foreign) top-level компания — блока «Тип компании» НЕТ',
    (tester) async {
      // roomId на ДРУГОМ домене, чем userID клиента → foreignCompanyKind==foreign.
      final foreign = _makeCompanyRoom(
        client,
        joinRule: JoinRules.public,
        domain: 'other.invalid',
      );
      await tester.pumpWidget(
        _wrapView(_viewForRoom(foreign, isChannel: false), client),
      );
      await _settle(tester);

      expect(
        find.text('Тип компании'),
        findsNothing,
        reason: 'на чужой компании нет прав — тумблер не показываем',
      );
    },
  );

  // AC:RL-company-access-settings-toggle/4
  testWidgets(
    'AC-4(company): обычная группа и канал — блока «Тип компании» НЕТ '
    '(взаимоисключение)',
    (tester) async {
      final group = _makeGroupRoom(client, joinRule: JoinRules.invite);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(group, isChannel: false), client),
      );
      await _settle(tester);
      expect(
        find.text('Тип компании'),
        findsNothing,
        reason: 'у обычной группы блока компании быть не должно',
      );

      final channel = _makeChannelRoom(client, joinRules: JoinRules.public);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(channel, isChannel: true), client),
      );
      await _settle(tester);
      expect(
        find.text('Тип компании'),
        findsNothing,
        reason: 'у канала блока компании быть не должно',
      );
    },
  );

  // AC:RL-company-access-settings-toggle/5
  testWidgets(
    'AC-5(company): на экране компании ровно ОДИН type-блок «Тип компании»; '
    '«Тип группы»/«Тип канала»/«Публичные адреса» отсутствуют',
    (tester) async {
      final room = _makeCompanyRoom(client, joinRule: JoinRules.public);
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      expect(find.text('Тип компании'), findsOneWidget);
      expect(
        find.byType(SegmentedButton<bool>),
        findsOneWidget,
        reason: 'ровно один тумблер — «Тип компании»',
      );
      expect(find.text('Тип группы'), findsNothing);
      expect(find.text('Тип канала'), findsNothing);
      // «Публичные адреса» и switch «Найти в поиске» directory-блока скрыты
      // (!isCompany) — иначе два контрола одной directory-видимости.
      expect(
        find.text('Адресы публичного чата'),
        findsNothing,
        reason: 'блок публичных адресов/directory не должен течь на компанию',
      );
    },
  );

  // AC:RL-company-access-settings-toggle/8
  testWidgets(
    'AC-8(company): участник без права (PL 0) — тумблер «Тип компании» '
    'неактивен (onSelectionChanged==null)',
    (tester) async {
      final room = _makeCompanyRoom(
        client,
        joinRule: JoinRules.invite,
        selfAdmin: false,
      );
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      expect(find.text('Тип компании'), findsOneWidget);
      final btn = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>),
      );
      expect(
        btn.onSelectionChanged,
        isNull,
        reason:
            'PL 0 (canChangeJoinRules=false) → тумблер обязан быть неактивен',
      );
    },
  );

  // AC:RL-company-access-settings-toggle/8 (позитив: админ — активен)
  testWidgets(
    'AC-8(company): админ компании (PL 100) — тумблер «Тип компании» активен',
    (tester) async {
      final room = _makeCompanyRoom(
        client,
        joinRule: JoinRules.invite,
        selfAdmin: true,
      );
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);

      final btn = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>),
      );
      expect(
        btn.onSelectionChanged,
        isNotNull,
        reason: 'админ (canChangeJoinRules=true) → тумблер активен',
      );
    },
  );

  // AC:RL-company-access-settings-toggle/6
  test(
    'AC-6(company): setCompanyPublic пишет join_rules + directory и НЕ трогает '
    'world_readable/setHistoryVisibility (у space нет peek-ленты)',
    () {
      const path =
          'lib/pages/chat_access_settings/chat_access_settings_controller.dart';
      final source = File(path).readAsStringSync();

      final start = source.indexOf('Future<void> setCompanyPublic');
      expect(
        start,
        greaterThan(-1),
        reason: 'Метод setCompanyPublic обязан существовать',
      );

      final bodyStart = source.indexOf('{', start);
      var depth = 0;
      var bodyEnd = -1;
      for (var i = bodyStart; i < source.length; i++) {
        if (source[i] == '{') depth++;
        if (source[i] == '}') {
          depth--;
          if (depth == 0) {
            bodyEnd = i;
            break;
          }
        }
      }
      expect(bodyEnd, greaterThan(-1));
      final body = source.substring(bodyStart, bodyEnd);

      expect(
        body.contains('setHistoryVisibility'),
        isFalse,
        reason: 'setCompanyPublic не должен трогать видимость истории',
      );
      expect(
        body.contains('worldReadable'),
        isFalse,
        reason:
            'публичная компания НЕ world_readable — иначе история читается '
            'анонимно (privacy-дыра)',
      );
      expect(body.contains('setJoinRules'), isTrue);
      expect(body.contains('setRoomVisibilityOnDirectory'), isTrue);
    },
  );

  // AC:RL-company-access-settings-toggle/7
  test(
    'AC-7(company): setCompanyPublic — makePublic→join_rules public+directory '
    'public; else→invite+private',
    () {
      const path =
          'lib/pages/chat_access_settings/chat_access_settings_controller.dart';
      final source = File(path).readAsStringSync();

      final start = source.indexOf('Future<void> setCompanyPublic');
      final elseIdx = source.indexOf('} else {', start);
      expect(
        elseIdx,
        greaterThan(start),
        reason: 'setCompanyPublic должен иметь ветку else (частная)',
      );

      final publicBranch = source.substring(start, elseIdx);
      final privateBranch = source.substring(
        elseIdx,
        source.indexOf('} catch', elseIdx),
      );

      expect(publicBranch.contains('JoinRules.public'), isTrue);
      expect(publicBranch.contains('Visibility.public'), isTrue);
      expect(privateBranch.contains('JoinRules.invite'), isTrue);
      expect(privateBranch.contains('Visibility.private'), isTrue);
    },
  );

  // ── LABA-2541: где живёт тумблер запрета сохранения контента и подсказка ──
  //
  // Тумблер обязан быть там, где у настройки есть предмет (группа, канал), и
  // отсутствовать там, где его нет (личный чат, пространство). В пространстве с
  // УЖЕ включённым флагом тумблер обязан остаться — иначе выключить его нечем.

  void setNoForwards(Room room, {required bool enabled}) => room.setState(
    _state(room, channelNoForwardsState, {'enabled': enabled}, ts: 1004),
  );

  // Заголовок тумблера одинаков у группы и канала — различаются только
  // подписи, поэтому один финдер обслуживает оба случая.
  Finder protectToggle() => find.ancestor(
    of: find.text('Запретить сохранение контента'),
    matching: find.byType(SwitchListTile),
  );

  // AC:RL-group-content-protection/1
  testWidgets('AC-1: в группе тумблер запрета сохранения контента ЕСТЬ', (
    tester,
  ) async {
    final room = _makeGroupRoom(client);
    await tester.pumpWidget(
      _wrapView(_viewForRoom(room, isChannel: false), client),
    );
    await _settle(tester);
    expect(protectToggle(), findsOneWidget);
  });

  // AC:RL-group-content-protection/11
  testWidgets('AC-11: в канале тумблер ЕСТЬ, в личном чате — НЕТ', (
    tester,
  ) async {
    final channel = _makeChannelRoom(client, joinRules: JoinRules.invite);
    await tester.pumpWidget(
      _wrapView(_viewForRoom(channel, isChannel: true), client),
    );
    await _settle(tester);
    expect(
      protectToggle(),
      findsOneWidget,
      reason: 'канал — предмет у настройки есть',
    );

    // `isDirectChat` SDK считает по account data `m.direct`, а не по summary.
    // Пишем account data напрямую: `handleSync` внутри testWidgets подвешивает
    // fake-async (реальный I/O в БД не дожидается тестового клока).
    final direct = _makeGroupRoom(client);
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: {
        '@bob:example.invalid': [direct.id],
      },
    );
    expect(
      direct.isDirectChat,
      isTrue,
      reason: 'подготовка кейса личного чата',
    );
    await tester.pumpWidget(
      _wrapView(_viewForRoom(direct, isChannel: false), client),
    );
    await _settle(tester);
    expect(
      protectToggle(),
      findsNothing,
      reason: 'в личном чате собеседник и так видит переписку',
    );
  });

  // AC:RL-group-content-protection/9
  testWidgets('AC-9: на пространстве тумблера НЕТ, пока флаг выключен', (
    tester,
  ) async {
    for (final room in [
      _makeCompanyRoom(client),
      _makeCompanyRoom(client, domain: 'other.invalid'),
    ]) {
      await tester.pumpWidget(
        _wrapView(_viewForRoom(room, isChannel: false), client),
      );
      await _settle(tester);
      expect(
        protectToggle(),
        findsNothing,
        reason:
            'у пространства нет ленты сообщений, а дочерние чаты флаг не '
            'наследуют — тумблер там только вводит в заблуждение',
      );
    }
  });

  // AC:RL-group-content-protection/10
  testWidgets('AC-10: на пространстве с ВКЛЮЧЁННЫМ флагом тумблер ОСТАЁТСЯ', (
    tester,
  ) async {
    final room = _makeCompanyRoom(client);
    setNoForwards(room, enabled: true);
    await tester.pumpWidget(
      _wrapView(_viewForRoom(room, isChannel: false), client),
    );
    await _settle(tester);
    expect(
      protectToggle(),
      findsOneWidget,
      reason: 'иначе включённый флаг нечем выключить — необратимая ловушка',
    );
  });

  // AC:RL-group-content-protection/12
  testWidgets(
    'AC-12: подсказка видна ровно при «флаг включён И я освобождён»',
    (tester) async {
      const hint =
          'Запрет включён, но на вас он не действует: у вас права модератора '
          'или администратора. Чтобы проверить, откройте чат под обычным '
          'участником.';

      Future<void> pumpGroup({
        required bool enabled,
        required int myPowerLevel,
      }) async {
        final room = _makeGroupRoom(client);
        room.setState(
          _state(room, EventTypes.RoomPowerLevels, {
            'state_default': 50,
            'events_default': 0,
            'users_default': 0,
            'users': {client.userID!: myPowerLevel},
          }, ts: 1003),
        );
        setNoForwards(room, enabled: enabled);
        await tester.pumpWidget(
          _wrapView(_viewForRoom(room, isChannel: false), client),
        );
        await _settle(tester);
      }

      await pumpGroup(enabled: true, myPowerLevel: 100);
      expect(find.text(hint), findsOneWidget, reason: 'админ + флаг включён');

      await pumpGroup(enabled: true, myPowerLevel: 50);
      expect(
        find.text(hint),
        findsOneWidget,
        reason: 'модератор + флаг включён',
      );

      await pumpGroup(enabled: false, myPowerLevel: 100);
      expect(
        find.text(hint),
        findsNothing,
        reason: 'флаг выключен — нечего пояснять',
      );

      await pumpGroup(enabled: true, myPowerLevel: 0);
      expect(
        find.text(hint),
        findsNothing,
        reason: 'участник под запретом — подсказка про освобождение ему лжёт',
      );
    },
  );
}
