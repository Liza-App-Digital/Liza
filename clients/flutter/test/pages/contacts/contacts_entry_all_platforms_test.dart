// ignore_for_file: depend_on_referenced_packages
// ledger:RL-contacts-entry-avatar-all-platforms
//
// «Контакты» одинаково на всех платформах (замечание Надежды 20.10): пункт в
// меню аватара без гейта платформы; на десктопе/web экран — собеседники из
// личных чатов (РЕАЛЬНЫЕ dmContactPeers и ContactsPage на реальных Room;
// классификатор — РЕАЛЬНЫЙ MatrixState.isBotOrAiUser, каталог ролей подменён).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/contacts/contacts_page.dart';
import 'package:liza/pages/contacts/dm_contacts_view.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/widgets/matrix.dart';

import '../../utils/search_sections_stubs.dart';
import '../../utils/test_client.dart';

const _companyBot = '@cup_bot:liza.cyber-agro.ru';

void main() {
  late Client client;
  late StubRoleService roles;
  late MatrixState matrix;
  final direct = <String, List<String>>{};

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    client.rooms.clear();
    direct.clear();
    roles = StubRoleService(client, serverAi: {_companyBot});
    matrix = SearchTestMatrixState(client, roles);
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await client.dispose(closeDatabase: true);
  });

  Room addRoom(
    String id, {
    String? dmWith,
    String? name,
    String partnerMembership = 'join',
    int lastTs = 1000,
    Map<String, Object?>? createContent,
    bool lizaRequest = false,
  }) {
    final room = Room(id: id, client: client);
    if (createContent != null) {
      room.setState(
        Event(
          eventId: '\$create-$id',
          senderId: client.userID!,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
          type: EventTypes.RoomCreate,
          stateKey: '',
          content: createContent,
          room: room,
        ),
      );
    }
    if (lizaRequest) {
      room.setState(
        Event(
          eventId: '\$req-$id',
          senderId: client.userID!,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
          type: lizaRequestStateType,
          stateKey: '',
          content: const {},
          room: room,
        ),
      );
    }
    if (dmWith != null) {
      room.setState(
        Event(
          eventId: '\$member-$id',
          senderId: dmWith,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
          type: EventTypes.RoomMember,
          stateKey: dmWith,
          content: {
            'membership': partnerMembership,
            if (name != null) 'displayname': name,
          },
          room: room,
        ),
      );
      direct.putIfAbsent(dmWith, () => []).add(id);
      client.accountData['m.direct'] = BasicEvent(
        type: 'm.direct',
        content: direct,
      );
    }
    room.lastEvent = Event(
      eventId: '\$last-$id',
      senderId: dmWith ?? client.userID!,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(lastTs),
      type: EventTypes.Message,
      content: const {'msgtype': 'm.text', 'body': 'привет'},
      room: room,
    );
    client.rooms.add(room);
    return room;
  }

  void seedMixedRooms() {
    // Свежий DM с Анной идёт ПЕРВЫМ: «последний перезаписывает» дал бы старый.
    addRoom(
      '!anna-new',
      dmWith: '@anna:example.invalid',
      name: 'Анна',
      lastTs: 5000,
    );
    addRoom(
      '!anna-old',
      dmWith: '@anna:example.invalid',
      name: 'Анна',
      lastTs: 100,
    );
    addRoom(
      '!ivan',
      dmWith: '@ivan:nadezhda.liza.ru',
      name: 'Иван',
      lastTs: 3000,
    );
    addRoom('!noname', dmWith: '@petr:example.invalid', lastTs: 2000);
    addRoom('!liza', dmWith: MatrixState.lizaMxid, name: 'Лиза', lastTs: 9000);
    addRoom('!bf', dmWith: '@bot_father:bots.liza.ru', name: 'BotFather');
    addRoom('!cup', dmWith: _companyBot, name: 'Бот компании');
    addRoom(
      '!gone',
      dmWith: '@olga:example.invalid',
      name: 'Ольга',
      partnerMembership: 'leave',
    );
    addRoom(
      '!banned',
      dmWith: '@spam:example.invalid',
      name: 'Спамер',
      partnerMembership: 'ban',
    );
    addRoom(
      '!req',
      dmWith: '@kate:example.invalid',
      name: 'Запрос',
      lizaRequest: true,
    );
    addRoom('!group', createContent: const {});
    addRoom('!space', createContent: const {'type': 'm.space'});
  }

  // AC:RL-contacts-entry-avatar-all-platforms/4
  test('AC-4: dmContactPeers — люди из DM: дедуп, без ботов (домен и роль ai), '
      'без ушедших/забаненных, без запросов к Лизе и групп, свежие сверху, '
      'имя из стейта или localpart', () async {
    seedMixedRooms();
    await roles.fetchRoles([_companyBot]);

    final peers = dmContactPeers(client.rooms, isBotOrAi: matrix.isBotOrAiUser);

    expect(peers.map((p) => p.userId), [
      '@anna:example.invalid',
      '@ivan:nadezhda.liza.ru',
      '@petr:example.invalid',
    ]);
    expect(peers.map((p) => p.displayName), ['Анна', 'Иван', 'petr']);
    expect(
      peers.first.lastActivity,
      DateTime.fromMillisecondsSinceEpoch(5000),
      reason: 'из двух DM с Анной берётся свежий',
    );
  });

  // AC:RL-contacts-entry-avatar-all-platforms/4
  test('AC-4: бот компании без роли ai в кэше попадает в список, с ролью — нет '
      '(поэтому экран ждёт каталог ролей)', () async {
    addRoom('!cup', dmWith: _companyBot, name: 'Бот компании');
    List<String> ids() => dmContactPeers(
      client.rooms,
      isBotOrAi: matrix.isBotOrAiUser,
    ).map((p) => p.userId).toList();

    expect(ids(), [_companyBot]);
    await roles.fetchRoles([_companyBot]);
    expect(ids(), isEmpty);
  });

  // AC:RL-contacts-entry-avatar-all-platforms/3
  testWidgets('AC-3: десктоп/web — подсказка про телефонную книгу, «Пригласить '
      'контакт», собеседники без ботов; flutter_contacts не вызывается', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await L10n.delegate.load(const Locale('ru'));
      seedMixedRooms();
    });

    await tester.pumpWidget(
      wrapWithMatrix(matrix, ContactsPage(useDeviceContacts: false)),
    );
    // Ожидание ролей ограничено таймером — промотать его в fake-async.
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    // Плагин телефонной книги на десктопе бросил бы MissingPluginException.
    expect(tester.takeException(), isNull);
    expect(find.text('Контакты'), findsOneWidget, reason: 'заголовок экрана');
    expect(
      find.textContaining('Контакты из телефонной книги доступны в мобильном'),
      findsOneWidget,
    );
    expect(find.text('Пригласить контакт'), findsOneWidget);
    expect(find.text('Ваши собеседники'), findsOneWidget);
    for (final name in ['Анна', 'Иван', 'petr']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    for (final hidden in [
      'Лиза',
      'BotFather',
      'Бот компании',
      'Ольга',
      'Спамер',
      'Запрос',
    ]) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }
    expect(find.text('Написать'), findsNWidgets(3));
  });

  // AC:RL-contacts-entry-avatar-all-platforms/3
  testWidgets(
    'AC-3: нет личных чатов — «Нет контактов», приглашение остаётся',
    (tester) async {
      await tester.runAsync(() => L10n.delegate.load(const Locale('ru')));
      await tester.pumpWidget(
        wrapWithMatrix(matrix, ContactsPage(useDeviceContacts: false)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Пригласить контакт'), findsOneWidget);
      expect(find.text('Ваши собеседники'), findsNothing);
      expect(
        find.text(
          L10n.of(tester.element(find.byType(ContactsPage))).noContactsToShow,
        ),
        findsOneWidget,
      );
    },
  );

  // AC:RL-contacts-entry-avatar-all-platforms/2
  test('AC-2: пункт «Контакты» в меню аватара без гейта платформы и ведёт на '
      '/rooms/contacts; экран сам выбирает источник по платформе', () {
    final menu = File(
      'lib/pages/chat_list/client_chooser_button.dart',
    ).readAsStringSync();
    expect(menu, contains('value: SettingsAction.contacts'));
    expect(menu, contains("context.go('/rooms/contacts')"));
    // Любой гейт платформы вокруг пунктов меню вернул бы разницу
    // Android/Windows, на которую жаловалась Надежда.
    expect(menu.contains('PlatformInfos'), isFalse);

    final page = File(
      'lib/pages/contacts/contacts_page.dart',
    ).readAsStringSync();
    expect(
      page,
      contains(
        'useDeviceContacts = useDeviceContacts ?? PlatformInfos.isMobile',
      ),
    );
    expect(page, contains('? const DmContactsView()'));
  });

  // AC:RL-contacts-entry-avatar-all-platforms/5
  testWidgets('AC-5: мобильная ветка — телефонная книга: экран спрашивает '
      'доступ к контактам, при отказе — экран разрешения, а не собеседники', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await L10n.delegate.load(const Locale('ru'));
      seedMixedRooms();
    });
    const channel = MethodChannel('github.com/QuisApp/flutter_contacts');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return call.method == 'requestPermission' ? false : null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await tester.pumpWidget(
      wrapWithMatrix(matrix, ContactsPage(useDeviceContacts: true)),
    );
    await tester.pumpAndSettle();

    expect(calls, ['requestPermission']);
    expect(find.byType(ContactsPermissionView), findsOneWidget);
    expect(find.byType(DmContactsView), findsNothing);
    expect(
      find.text('Анна'),
      findsNothing,
      reason: 'собеседники — только десктоп',
    );
  });
}
