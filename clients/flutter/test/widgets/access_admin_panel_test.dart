// ignore_for_file: depend_on_referenced_packages
// ledger:RL-company-members-access

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_members/access_admin_panel.dart';
import 'package:liza/utils/access_admin_service.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../utils/test_client.dart';

// Аватарки в панели рендерятся через общий Avatar/MxcImage, который
// безусловно резолвит клиента через Matrix.of(context), даже когда
// mxContent==null и грузить нечего. Без хотя бы одного клиента в дереве
// это падает на Provider.of<MatrixState>() и уходит в бесконечный ретрай
// с реальными Timer'ами, несовместимый с pumpAndSettle в тестах. Полноценный
// Matrix-виджет поднимать в юнит-тесте виджета неоправданно тяжело (пуши,
// VoIP, connectivity) — подменяем только то, что читает Avatar: геттер client.
class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);

  final Client _client;

  @override
  Client get client => _client;
}

AccessDossier _dossier({
  bool deactivated = false,
  bool isLocal = true,
  List<DossierEntry> spaces = const [],
  List<DossierEntry> channels = const [],
  List<DossierEntry> chats = const [],
  List<DossierEntry> bots = const [],
}) =>
    AccessDossier(
      displayName: 'Иван',
      deactivated: deactivated,
      isLocal: isLocal,
      serverName: 'srv',
      roleLabel: 'Пользователь',
      spaces: spaces,
      channels: channels,
      chats: chats,
      bots: bots,
    );

Widget _wrap(Widget child, Client client) => MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Provider<liza_matrix.MatrixState>.value(
        value: _TestMatrixState(client),
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

/// Обёртка с реальным GoRouter: тап по кликабельной сущности зовёт
/// `context.push('/rooms/<id>')`, и маршрут `/rooms/:roomid` рендерит маркер
/// `ROOM:<id>` — так навигация проверяется по факту, а не по колбэку-реплике.
Widget _routerApp(Widget panel, Client client) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            Scaffold(body: SingleChildScrollView(child: panel)),
      ),
      GoRoute(
        path: '/rooms/:roomid',
        builder: (context, state) =>
            Scaffold(body: Text('ROOM:${state.pathParameters['roomid']}')),
      ),
    ],
  );
  return Provider<liza_matrix.MatrixState>.value(
    value: _TestMatrixState(client),
    child: MaterialApp.router(
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      routerConfig: router,
    ),
  );
}

void main() {
  late Client client;

  setUp(() async {
    client = await prepareTestClient();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  testWidgets('показывает имя сервера и роль', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(dossier: _dossier(), onToggleActive: () {}),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('srv'), findsOneWidget);
    expect(find.text('Пользователь'), findsOneWidget);
  });

  testWidgets('показывает группу компаний с уровнем', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(
          dossier: _dossier(
            spaces: const [
              DossierEntry(
                roomId: '!s:srv',
                name: 'Компания',
                level: AccessLevel.admin,
              ),
            ],
          ),
          onToggleActive: () {},
        ),
        client,
      ),
    );
    await tester.pumpAndSettle();
    // "Компании" встречается дважды: чип-фильтр + заголовок группы.
    expect(find.text('Компании'), findsWidgets);
    expect(find.text('Компания'), findsOneWidget);
    expect(find.text('Администратор'), findsWidgets);
  });

  testWidgets('пустые группы не отображаются', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(dossier: _dossier(), onToggleActive: () {}),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Каналы'), findsNothing);
    expect(find.text('Чаты'), findsNothing);
  });

  testWidgets('показывает заглушку когда членств нет', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(dossier: _dossier(), onToggleActive: () {}),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Нет членств на этом сервере'), findsOneWidget);
  });

  testWidgets('активный аккаунт — кнопка деактивации', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(dossier: _dossier(), onToggleActive: () {}),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Деактивировать аккаунт'), findsOneWidget);
    expect(find.text('Реактивировать аккаунт'), findsNothing);
  });

  testWidgets('деактивированный аккаунт — кнопка реактивации', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(
          dossier: _dossier(deactivated: true),
          onToggleActive: () {},
        ),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Реактивировать аккаунт'), findsOneWidget);
    expect(find.text('Деактивировать аккаунт'), findsNothing);
  });

  testWidgets('кнопка вызывает колбэк', (tester) async {
    var called = 0;
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(dossier: _dossier(), onToggleActive: () => called++),
        client,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Деактивировать аккаунт'));
    await tester.pump();
    expect(called, 1);
  });

  testWidgets('чужой сервер — кнопка заблокирована с пояснением',
      (tester) async {
    var called = 0;
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(
          dossier: _dossier(isLocal: false),
          onToggleActive: () => called++,
        ),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Аккаунт принадлежит другому серверу'), findsOneWidget);
    await tester.tap(find.text('Деактивировать аккаунт'));
    await tester.pump();
    expect(called, 0);
  });

  testWidgets('показывает группу ботов с уровнем', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(
          dossier: _dossier(
            bots: const [
              DossierEntry(
                roomId: '!b:srv',
                name: 'Бот',
                level: AccessLevel.user,
              ),
            ],
          ),
          onToggleActive: () {},
        ),
        client,
      ),
    );
    await tester.pumpAndSettle();
    // "Боты" встречается дважды: чип-фильтр + заголовок группы.
    expect(find.text('Боты'), findsWidgets);
    expect(find.text('Бот'), findsOneWidget);
  });

  testWidgets('запись без имени показывает плейсхолдер', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(
          dossier: _dossier(
            chats: const [
              DossierEntry(
                roomId: '!noname:srv',
                name: null,
                level: AccessLevel.user,
              ),
            ],
          ),
          onToggleActive: () {},
        ),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Без названия'), findsOneWidget);
    expect(find.text('!noname:srv'), findsNothing);
  });

  testWidgets('чипы-фильтры показаны и по умолчанию выбран "Все"',
      (tester) async {
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(
          dossier: _dossier(
            spaces: const [
              DossierEntry(
                roomId: '!s:srv',
                name: 'Компания',
                level: AccessLevel.admin,
              ),
            ],
            chats: const [
              DossierEntry(
                roomId: '!c:srv',
                name: 'Чат',
                level: AccessLevel.user,
              ),
            ],
          ),
          onToggleActive: () {},
        ),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Все'), findsOneWidget);
    // "Боты" — только чип-фильтр, группы ботов в досье нет.
    expect(find.text('Боты'), findsOneWidget);
    final allChip = tester.widget<ChoiceChip>(
      find.ancestor(
        of: find.text('Все'),
        matching: find.byType(ChoiceChip),
      ),
    );
    expect(allChip.selected, isTrue);
    expect(find.text('Компания'), findsOneWidget);
    expect(find.text('Чат'), findsOneWidget);
  });

  testWidgets('выбор чипа фильтрует группы', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AccessAdminPanel(
          dossier: _dossier(
            spaces: const [
              DossierEntry(
                roomId: '!s:srv',
                name: 'Компания',
                level: AccessLevel.admin,
              ),
            ],
            chats: const [
              DossierEntry(
                roomId: '!c:srv',
                name: 'Чат',
                level: AccessLevel.user,
              ),
            ],
          ),
          onToggleActive: () {},
        ),
        client,
      ),
    );
    await tester.pumpAndSettle();

    final chatsChip = find.ancestor(
      of: find.text('Чаты'),
      matching: find.byType(ChoiceChip),
    );
    await tester.tap(chatsChip);
    await tester.pumpAndSettle();

    expect(find.text('Компания'), findsNothing);
    expect(find.text('Чат'), findsOneWidget);
  });

  // AC:RL-company-members-access/16 — подписи чекбоксов фильтра: «На сервере
  // {домен}» и «В компании {имя}» (RL-member-filter-useful-checkboxes AC-8/9;
  // guard от отката строки; визуальная проверка — manual M-7). Читаем
  // реальный сгенерированный L10n, а не литерал.
  testWidgets('короткие подписи чекбоксов фильтра (ru)', (tester) async {
    L10n? l10n;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = L10n.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(l10n!.memberFilterOnServer('Агро'), 'На сервере Агро');
    expect(l10n!.memberFilterInCompany('Розенталь'), 'В компании Розенталь');
  });

  // AC:RL-company-members-access/18 — достижимый чат (владелец сам в нём,
  // membership=join) кликабелен; тап навигирует в его комнату.
  testWidgets('достижимая сущность кликабельна и навигирует', (tester) async {
    client.rooms.add(Room(id: '!c:srv', client: client));
    await tester.pumpWidget(
      _routerApp(
        AccessAdminPanel(
          dossier: _dossier(
            chats: const [
              DossierEntry(roomId: '!c:srv', name: 'Живой чат', level: AccessLevel.admin),
            ],
          ),
          onToggleActive: () {},
        ),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsWidgets);
    await tester.tap(find.text('Живой чат'));
    await tester.pumpAndSettle();
    expect(find.text('ROOM:!c:srv'), findsOneWidget);
  });

  // AC:RL-company-members-access/19 — недостижимая безымянная запись НЕ скрыта:
  // видна с плейсхолдером «Без названия», тап не навигирует (red-proof к AC-18).
  testWidgets('недостижимая безымянная запись видна и не навигирует',
      (tester) async {
    await tester.pumpWidget(
      _routerApp(
        AccessAdminPanel(
          dossier: _dossier(
            chats: const [
              DossierEntry(roomId: '!ghost:srv', name: null, level: AccessLevel.admin),
            ],
          ),
          onToggleActive: () {},
        ),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Без названия'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    await tester.tap(find.text('Без названия'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ROOM:'), findsNothing);
  });

  // AC:RL-company-members-access/20 — комната есть в сторе, но membership!=join
  // (left/архив): НЕ кликабельна. Гейт по membership, а не getRoomById!=null.
  testWidgets('left-комната в сторе не кликабельна', (tester) async {
    client.rooms.add(
      Room(id: '!left:srv', client: client, membership: Membership.leave),
    );
    await tester.pumpWidget(
      _routerApp(
        AccessAdminPanel(
          dossier: _dossier(
            chats: const [
              DossierEntry(roomId: '!left:srv', name: 'Покинутый', level: AccessLevel.admin),
            ],
          ),
          onToggleActive: () {},
        ),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Покинутый'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    await tester.tap(find.text('Покинутый'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ROOM:'), findsNothing);
  });

  // AC:RL-company-members-access/21 — запись-пространство не кликабельна даже
  // при достижимости (space открывается через setActiveSpace, не /rooms).
  testWidgets('пространство не кликабельно даже если достижимо', (tester) async {
    client.rooms.add(Room(id: '!sp:srv', client: client));
    await tester.pumpWidget(
      _routerApp(
        AccessAdminPanel(
          dossier: _dossier(
            spaces: const [
              DossierEntry(roomId: '!sp:srv', name: 'Компания', level: AccessLevel.admin),
            ],
          ),
          onToggleActive: () {},
        ),
        client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Компания'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    await tester.tap(find.text('Компания'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ROOM:'), findsNothing);
  });
}
