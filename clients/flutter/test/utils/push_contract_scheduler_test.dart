// ledger:RL-push-causal-contract
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/push_contract.dart';
import 'package:liza/utils/push_contract_outbox.dart';
import 'package:liza/utils/push_contract_session.dart';
import 'package:liza/utils/push_contract_transport.dart';

class _Principal extends Fake implements Client {
  _Principal(this.index);
  final int index;
  @override
  String get userID => '@a$index:example.test';
  @override
  String get deviceID => 'device$index';
  @override
  Uri get homeserver => Uri.parse('https://issuer.test');
  @override
  String get accessToken => 'only-for-this-request-$index';
  @override
  bool isLogged() => true;
  @override
  String get prevBatch => 'commit';
  @override
  final rooms = <Room>[];
  @override
  final onSync = CachedStreamController<SyncUpdate>();
  @override
  final onSyncStatus = CachedStreamController<SyncStatusUpdate>();
  Future<void> committed() async {
    onSyncStatus.add(const SyncStatusUpdate(SyncStatus.waitingForResponse));
    onSyncStatus.add(const SyncStatusUpdate(SyncStatus.processing));
    await Future<void>.delayed(Duration.zero);
    onSync.add(SyncUpdate(nextBatch: prevBatch));
    await Future<void>.delayed(Duration.zero);
    onSyncStatus.add(const SyncStatusUpdate(SyncStatus.cleaningUp));
    onSyncStatus.add(const SyncStatusUpdate(SyncStatus.finished));
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    '16 аккаунтов получают очередь, семнадцатый отражён как coverage; бюджет включает status',
    () async {
      var now = 1000000;
      final calls = <({int time, String? user})>[];
      final clients = List.generate(17, _Principal.new);
      final scheduler = PushContractScheduler(
        clients: () => clients,
        active: () => clients.last,
        lifecycle: () => 'resumed',
        endpoint: (_) => Uri.parse('https://api.example.test/liza/push/v1/'),
        clock: () => now,
        build: () async => '12',
        queue: PushContractOutbox(),
        network: PushContractTransport(
          open: () => MockClient((req) async {
            if (req.method == 'GET') {
              expect(req.headers['Authorization'], isNull);
              calls.add((time: now, user: null));
              return http.Response('{"contract":true}', 200);
            }
            final data = jsonDecode(req.body) as Map;
            final user = data['user_id'] as String;
            final source = clients.singleWhere((c) => c.userID == user);
            expect(
              req.headers['Authorization'],
              'Bearer ${source.accessToken}',
            );
            expect(data['coverage']['accounts_omitted'], 1);
            expect(data['session_id'], hasLength(32));
            expect(req.body, isNot(contains('only-for-this-request')));
            calls.add((time: now, user: user));
            return http.Response(
              jsonEncode({
                'schema': 1,
                'accepted': true,
                'batch_id': data['batch_id'],
                'results': [],
              }),
              200,
            );
          }),
        ),
      );
      addTearDown(scheduler.dispose);
      for (final client in clients) {
        scheduler.attach(client);
      }
      now += 2000;
      for (var i = 0; i < 16; i++) {
        await scheduler.runDue();
      }
      expect(calls.where((r) => r.user == null), hasLength(1));
      await Future.wait(clients.map((c) => c.committed()));
      for (var step = 0; step < 100; step++) {
        now += 2000;
        for (var i = 0; i < 17; i++) {
          await scheduler.runDue();
        }
        if (calls.map((c) => c.user).whereType<String>().toSet().length == 16) {
          break;
        }
      }
      expect(
        calls.map((c) => c.user).whereType<String>().toSet(),
        clients.take(16).map((c) => c.userID).toSet(),
      );
      for (final call in calls) {
        expect(
          calls
              .where((c) => c.time <= call.time && c.time > call.time - 60000)
              .length,
          lessThanOrEqualTo(8),
        );
        final times = calls
            .where((c) => c.user == call.user)
            .map((c) => c.time)
            .toList();
        for (var i = 1; i < times.length; i++) {
          expect(times[i] - times[i - 1], greaterThanOrEqualTo(15000));
        }
      } // AC:RL-push-causal-contract/8
    },
  );

  testWidgets(
    'зависший PackageInfo отпускает второй аккаунт и поздний build не перезаписывает новый',
    (tester) async {
      var now = 6000000, builds = 0;
      final clients = [_Principal(21), _Principal(22)];
      final hang = Completer<String>(), reported = <String>[];
      final scheduler = PushContractScheduler(
        clients: () => clients,
        active: () => clients.first,
        lifecycle: () => 'resumed',
        clock: () => now,
        endpoint: (_) => Uri.parse('https://api.example.test/'),
        queue: PushContractOutbox(),
        build: () => ++builds == 1 ? hang.future : Future.value('77'),
        network: PushContractTransport(
          open: () => MockClient((r) async {
            if (r.method == 'GET') {
              return http.Response('{"contract":true}', 200);
            }
            final data = jsonDecode(r.body);
            reported.add(data['build'] as String);
            return http.Response(
              jsonEncode({
                'schema': 1,
                'accepted': true,
                'batch_id': data['batch_id'],
                'results': [],
              }),
              200,
            );
          }),
        ),
      );
      addTearDown(scheduler.dispose);
      for (final c in clients) {
        scheduler.attach(c);
      }
      now += 2000;
      var firstDone = false;
      unawaited(
        scheduler.runDue().then((_) {
          firstDone = true;
        }),
      );
      await tester.pump();
      expect(builds, 1);
      now += 3000;
      await tester.pump(const Duration(seconds: 3));
      await scheduler.runDue();
      expect(firstDone, true);
      expect(builds, 2); // AC:RL-push-causal-contract/8
      hang.complete('999');
      await tester.pump();
      final b = clients.last;
      b.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.waitingForResponse));
      b.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.processing));
      await tester.pump();
      b.onSync.add(SyncUpdate(nextBatch: b.prevBatch));
      await tester.pump();
      b.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.cleaningUp));
      b.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.finished));
      await tester.pump();
      now += 15000;
      await scheduler.runDue();
      expect(reported, ['77']);
      scheduler.dispose();
    },
  );
  test(
    'зависший prefs load не блокирует outbox и поздний load не восстанавливает отменённый batch',
    () async {
      final hung = Completer<SharedPreferences>();
      var loads = 0;
      final q = PushContractOutbox(
        preferences: () =>
            ++loads == 1 ? hung.future : SharedPreferences.getInstance(),
      );
      ContractEnvelope e(String id) => ContractEnvelope(
        'https://example.test',
        5,
        'proof',
        jsonEncode({'batch_id': id, 'user_id': '@u:test', 'device_id': 'a'}),
      );
      await expectLater(q.add(e('stale'), 5), throwsA(isA<TimeoutException>()));
      await q.add(e('new'), 5);
      hung.complete(await SharedPreferences.getInstance());
      await Future<void>.delayed(Duration.zero);
      expect(
        (await q.first('https://example.test', '@u:test', 'a', 5))?.id,
        'new',
      );
    },
  );
  test(
    'после рестарта сохранённые восемь запросов блокируют даже статус',
    () async {
      var now = 8000000, calls = 0;
      SharedPreferences.setMockInitialValues({
        PushContractScheduler.budgetKey: List.filled(8, '$now'),
      });
      final c = _Principal(99);
      final scheduler = PushContractScheduler(
        clients: () => [c],
        active: () => c,
        lifecycle: () => 'resumed',
        clock: () => now,
        endpoint: (_) => Uri.parse('https://api.example.test/'),
        network: PushContractTransport(
          open: () => MockClient((req) async {
            calls++;
            return http.Response('{"contract":false}', 200);
          }),
        ),
      );
      addTearDown(scheduler.dispose);
      scheduler.attach(c);
      now += 2000;
      await scheduler.runDue();
      expect(calls, 0);
      now += 60001;
      await scheduler.runDue();
      expect(calls, 1);
    },
  );

  test(
    '401 прекращает отправку и очищает очередь только отклонённого устройства',
    () async {
      var now = 9000000, posts = 0;
      final c = _Principal(1), q = PushContractOutbox();
      final scheduler = PushContractScheduler(
        clients: () => [c],
        active: () => c,
        lifecycle: () => 'resumed',
        endpoint: (_) => Uri.parse('https://api.example.test/liza/push/v1/'),
        clock: () => now,
        build: () async => '5',
        queue: q,
        network: PushContractTransport(
          open: () => MockClient((req) async {
            if (req.method == 'GET') {
              return http.Response('{"contract":true}', 200);
            }
            posts++;
            return http.Response('', 401);
          }),
        ),
      );
      addTearDown(scheduler.dispose);
      await q.add(
        ContractEnvelope(
          c.homeserver.origin,
          now,
          'proof',
          jsonEncode({
            'batch_id': 'other',
            'user_id': c.userID,
            'device_id': 'a-peer',
          }),
        ),
        now,
      );
      scheduler.attach(c);
      now += 2000;
      await scheduler.runDue();
      await c.committed();
      now += 15000;
      await scheduler.runDue();
      expect(posts, 1);
      expect(PushContractSession.of(c), isNull);
      now += 60000;
      await scheduler.runDue();
      expect(posts, 1); // AC:RL-push-causal-contract/2
      expect(
        await q.first(c.homeserver.origin, c.userID, c.deviceID, now),
        isNull,
      );
      expect(
        (await q.first(c.homeserver.origin, c.userID, 'a-peer', now))?.id,
        'other',
      );
    },
  );
}
