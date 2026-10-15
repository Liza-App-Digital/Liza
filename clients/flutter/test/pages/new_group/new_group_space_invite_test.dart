// Страж задачи 13: новое пространство с РЕАЛЬНОГО экрана «Новое пространство»
// (NewGroup._createSpace) на инстансе-компании создаётся с порогом
// «приглашают только админы» — invite 99, events_default 100. На общем
// инстансе (single_space_guard без `company`) — прежнее тело без invite.
//
// Ассерт — по ТЕЛУ createRoom из FakeMatrixApi.calledEndpoints, класс инстанса —
// реальным SingleSpaceService.fetch() под MockClient (поле `company`).
//
// Red-proof: вернуть в _createSpace литерал `{'events_default': 100}` → кейс
// «компания» краснеет (invite отсутствует).
//
// ledger:RL-space-invite-admin-only
// AC:RL-space-invite-admin-only/1

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/new_group/new_group.dart';
import 'package:liza/widgets/matrix.dart';

import '../../utils/test_client.dart';

void main() {
  late Client client;
  late SharedPreferences store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
    store = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  List<Map<String, dynamic>> spaceCreateBodies() => [
    for (final b
        in FakeMatrixApi.calledEndpoints['/client/v3/createRoom'] ?? const [])
      if (jsonDecode(b as String) case final Map<String, dynamic> body
          when (body['creation_content'] as Map?)?['type'] == 'm.space')
        body,
  ];

  for (final (label, rootBody, expectInvite) in const [
    ('инстанс-компания', '{"exists":true,"room_id":"!r:x","company":true}', 99),
    ('общий инстанс', '{"exists":true,"room_id":"!r:x","company":false}', null),
    ('старый сервер без поля', '{"exists":true,"room_id":"!r:x"}', null),
  ]) {
    testWidgets('_createSpace, $label: invite=$expectInvite, '
        'events_default=100', (tester) async {
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
          home: Matrix(
            clients: [client],
            store: store,
            child: const NewGroup(createGroupType: CreateGroupType.space),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final service = tester
          .state<MatrixState>(find.byType(Matrix))
          .singleSpaceService;
      await tester.runAsync(
        () => http.runWithClient(
          service.fetch,
          () => MockClient((_) async => http.Response(rootBody, 200)),
        ),
      );
      expect(service.isCompanyInstance, expectInvite != null);

      FakeMatrixApi.calledEndpoints.clear();
      await tester.enterText(find.byType(TextField).first, 'Отдел');
      await tester.pump();
      await tester.tap(find.byType(ElevatedButton));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      // context.pop без GoRouter в обёртке бросает — не предмет теста.
      tester.takeException();

      final bodies = spaceCreateBodies();
      expect(bodies, hasLength(1));
      final pl = bodies.single['power_level_content_override'] as Map;
      expect(pl['events_default'], 100);
      expect(pl['invite'], expectInvite);
      expect(pl.containsKey('invite'), expectInvite != null);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 1));
    });
  }
}
