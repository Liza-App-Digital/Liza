// ledger:RL-push-report-outbox
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/push_journal.dart';
import 'package:liza/utils/push_report_outbox.dart';

import 'push_report_test_support.dart';
import 'per_user_fake_api.dart';
import 'test_client.dart';

Map<String, dynamic> payload({
  List<Map<String, Object?>> accounts = const [],
}) => {
  'title': Monitoring.pushReportTitle('ios'),
  'tags': <String, String>{},
  'context': Monitoring.pushReportContext(
    counters: {'apns_received': 2},
    journalTail: '',
    settings: {},
    accounts: accounts,
    nativeJournal: [],
    platform: 'ios',
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t0 = DateTime.utc(2026, 10, 30);

  // AC:RL-push-report-outbox/1
  test(
    'атомарный файл переживает restart с исходными id/account/payload',
    () async {
      final dir = await Directory.systemTemp.createTemp('push_outbox');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/outbox.json');
      final captured = <Map<String, dynamic>>[];
      PushReportOutbox open() => PushReportOutbox(
        store: FilePushReportStore(file: file),
        transport: () => CallbackPushReportTransport((report) {
          captured.add(report);
          return report['event_id'] as String;
        }),
      );
      final first = open();
      final original = payload(
        accounts: [
          {
            'user_id': '@first:example.org',
            'device_id': 'a',
            'homeserver': 'https://example.org',
          },
        ],
      );
      await first.enqueue(original, t0);
      original['context']['accounts'].clear();
      final before = await first.inspect();
      final second = open();
      expect(await second.inspect(), before);
      expect(await second.drain(t0), isTrue);
      expect(captured.single['payload']['context']['accounts'], hasLength(1));
      expect((await second.inspect())['reports'], isEmpty);
      expect(await File('${file.path}.tmp').exists(), isFalse);
    },
  );

  // AC:RL-push-report-outbox/2
  test(
    'throw/empty/mismatch оставляют pending; backoff 1..60min независимо от сбора',
    () async {
      final store = MemoryPushReportStore();
      var calls = 0;
      var answer = 'mismatch';
      final box = PushReportOutbox(
        store: store,
        transport: () => CallbackPushReportTransport((report) {
          calls++;
          if (answer == 'throw') throw StateError('offline');
          return answer == 'match' ? report['event_id'] as String : answer;
        }),
      );
      await box.enqueue(payload(), t0);
      var now = t0;
      for (final minutes in [1, 2, 4, 8, 16, 32, 60, 60]) {
        answer = calls.isEven ? 'throw' : '';
        expect(await box.drain(now), isFalse);
        final record = ((await box.inspect())['reports'] as List).single;
        expect(
          record['next_attempt'],
          now.add(Duration(minutes: minutes)).millisecondsSinceEpoch,
        );
        expect(await box.isDue(now), isFalse);
        now = now.add(Duration(minutes: minutes));
      }
      answer = 'mismatch';
      expect(await box.drain(now), isFalse);
      answer = 'match';
      expect(await box.drain(now.add(const Duration(hours: 1))), isTrue);
      expect((await box.inspect())['reports'], isEmpty);
    },
  );

  // AC:RL-push-report-outbox/3
  test(
    'лимиты count/bytes/TTL, corruption и oversized имеют счётчики',
    () async {
      final store = MemoryPushReportStore();
      final box = PushReportOutbox(
        store: store,
        transport: () => CallbackPushReportTransport((_) => null),
      );
      for (var i = 0; i < 9; i++) {
        await box.enqueue(
          payload(),
          t0.add(Duration(minutes: i)),
          manual: true,
        );
      }
      var state = await box.inspect();
      expect(state['reports'], hasLength(7));
      expect(state['evicted'], 2);
      expect(
        utf8.encode(store.value!).length,
        lessThanOrEqualTo(PushReportOutbox.maxBytes),
      );
      final big = payload();
      big['context']['journal'] = 'x' * (256 * 1024);
      expect(
        await box.enqueue(
          big,
          t0.add(const Duration(minutes: 10)),
          manual: true,
        ),
        isFalse,
      );
      state = await box.inspect();
      expect(state['oversized'], 1);
      await box.drain(t0.add(const Duration(days: 8)));
      expect((await box.inspect())['expired'], 7);
      store.value = 'broken JSON';
      final recovered = PushReportOutbox(
        store: store,
        transport: () => CallbackPushReportTransport((_) => null),
      );
      await recovered.enqueue(payload(), t0);
      expect((await recovered.inspect())['corrupt'], 1);
    },
  );

  test('байтовый лимит вытесняет целые старые записи', () async {
    final store = MemoryPushReportStore();
    final box = PushReportOutbox(
      store: store,
      transport: () => CallbackPushReportTransport((_) => null),
    );
    for (var i = 0; i < 6; i++) {
      final value = payload();
      value['context']['journal'] = 'я' * 24000;
      await box.enqueue(value, t0.add(Duration(minutes: i)), manual: true);
    }
    final state = await box.inspect();
    expect((state['reports'] as List).length, lessThan(6));
    expect(state['evicted'], greaterThan(0));
    expect(
      utf8.encode(store.value!).length,
      lessThanOrEqualTo(PushReportOutbox.maxBytes),
    );
  });

  // AC:RL-push-report-outbox/4
  test(
    'ошибка записи не закрывает окно; manual cooldown одна минута',
    () async {
      final store = MemoryPushReportStore()..failWrite = true;
      final box = PushReportOutbox(
        store: store,
        transport: () => CallbackPushReportTransport((_) => null),
      );
      await expectLater(box.enqueue(payload(), t0), throwsStateError);
      expect(await box.isDue(t0), isTrue);
      store.failWrite = false;
      expect(await box.enqueue(payload(), t0), isTrue);
      expect(await box.enqueue(payload(), t0, manual: true), isTrue);
      expect(
        await box.enqueue(
          payload(),
          t0.add(const Duration(seconds: 59)),
          manual: true,
        ),
        isFalse,
      );
      expect(
        await box.enqueue(
          payload(),
          t0.add(const Duration(minutes: 1)),
          manual: true,
        ),
        isTrue,
      );
    },
  );

  // AC:RL-push-report-outbox/5
  test(
    'конкурентные enqueue/drain сериализованы, timeout закрывает transport, late ACK инертен',
    () async {
      final store = MemoryPushReportStore();
      final late = Completer<String?>();
      String? expected;
      var calls = 0;
      var closed = 0;
      final box = PushReportOutbox(
        store: store,
        timeout: const Duration(milliseconds: 10),
        transport: () => CallbackPushReportTransport((report) {
          calls++;
          expected = report['event_id'] as String;
          return late.future;
        }, onClose: () => closed++),
      );
      expect(
        await Future.wait([
          box.enqueue(payload(), t0),
          box.enqueue(payload(), t0),
        ]),
        [true, false],
      );
      await Future.wait([box.drain(t0), box.drain(t0)]);
      expect(calls, 1);
      expect(closed, 1);
      final before = store.value;
      late.complete(expected);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.value, before);
      expect((await box.inspect())['reports'], hasLength(1));
      await box.drain(t0.add(const Duration(minutes: 1)), canSend: () => false);
      expect(calls, 1);
    },
  );

  // AC:RL-push-report-outbox/6
  test(
    'production context сохраняет 0/1/2 same-HS/2 different-HS/3 accounts точно',
    () {
      for (final hosts in <List<String>>[
        [],
        ['one'],
        ['one', 'one'],
        ['one', 'two'],
        ['one', 'two', 'three'],
      ]) {
        final accounts = [
          for (var i = 0; i < hosts.length; i++)
            {
              'user_id': '@very_long_account_name_${'x' * 40}:$i.${hosts[i]}',
              'device_id': 'device_${'d' * 40}_$i',
              'homeserver': 'https://${hosts[i]}.example.org',
            },
        ];
        final context = payload(accounts: accounts)['context'] as Map;
        expect(context['accounts'], accounts);
        expect(
          context['counters']['apns_received'],
          2,
          reason: 'общие counters не копируются по аккаунтам',
        );
        expect(context['coverage']['os_display'], 'unknown');
        expect(context['coverage']['native_received'], 'unknown');
      }
      final accounts = List.generate(
        17,
        (i) => <String, Object?>{'user_id': '@$i:example.org'},
      );
      final context = payload(accounts: accounts)['context'];
      expect(context['coverage']['truncated'], isTrue);
      expect(context['accounts'], hasLength(16));
    },
  );

  test(
    'production collector копирует logged accounts и безопасные rules до logout',
    () async {
      final clients = <Client>[];
      addTearDown(() async {
        for (final client in clients) {
          await client.dispose();
        }
      });
      for (final host in [
        'same.example.org',
        'same.example.org',
        'other.example.org',
      ]) {
        final user = '@long_account_${'x' * 40}_${clients.length}:$host';
        final client = await prepareTestClient(
          loggedIn: true,
          clientName: 'account_${clients.length}',
          userId: user,
          homeserver: Uri.parse('https://$host'),
          httpClient: PerUserFakeMatrixApi(userId: user, homeserverHost: host),
        );
        clients.add(client);
      }
      expect(Monitoring.collectPushAccounts(const []), isEmpty);
      for (final indexes in [
        [0],
        [0, 1],
        [0, 2],
        [0, 1, 2],
      ]) {
        final selected = indexes.map((i) => clients[i]).toList();
        final accounts = Monitoring.collectPushAccounts(selected);
        expect(accounts, hasLength(indexes.length));
        for (var i = 0; i < selected.length; i++) {
          expect(accounts[i]['user_id'], selected[i].userID);
          expect(accounts[i]['device_id'], selected[i].deviceID);
          expect(accounts[i]['homeserver'], selected[i].homeserver.toString());
          expect(accounts[i]['registration'], 'unknown');
        }
        selected.clear();
        expect(accounts, hasLength(indexes.length));
      }
    },
  );

  // AC:RL-push-report-outbox/8
  test(
    'отдельный HTTP клиент не наследует scope/attachments/breadcrumbs',
    () async {
      const poison = 'PRIVATE_GLOBAL_SCOPE';
      await Sentry.init((options) {
        options.dsn = 'https://public@example.org/1';
        options.sendDefaultPii = false;
      });
      addTearDown(Sentry.close);
      await Sentry.configureScope((scope) {
        scope.setTag('private_scope', poison);
        scope.setUser(SentryUser(id: poison));
        scope.addBreadcrumb(Breadcrumb(message: poison));
        scope.addAttachment(
          SentryAttachment.fromIntList(utf8.encode(poison), '$poison.txt'),
        );
      });
      final store = MemoryPushReportStore();
      String? id;
      String? envelope;
      final box = PushReportOutbox(
        store: store,
        transport: () => SentryPushReportTransport(
          dsn: 'https://public@example.org/1',
          environment: 'test',
          httpClient: MockClient((request) async {
            envelope = utf8.decode(
              request.headers['content-encoding'] == 'gzip'
                  ? gzip.decode(request.bodyBytes)
                  : request.bodyBytes,
            );
            return http.Response(jsonEncode({'id': id}), 200);
          }),
        ),
      );
      await box.enqueue(payload(), t0);
      id =
          ((await box.inspect())['reports'] as List).single['event_id']
              as String;
      expect(await box.drain(t0), isTrue);
      expect(envelope, isNotNull);
      expect(envelope, isNot(contains(poison)));
      expect(envelope, contains('push-report'));
    },
  );

  // AC:RL-push-report-outbox/9
  test('metadata hash и local_shown соответствуют production журналу', () {
    const eventId = r'$qbjlZmg14Tcfdz3P6kXuPC8:vector';
    final expected = sha256
        .convert(utf8.encode(eventId))
        .toString()
        .substring(0, 8);
    final context = payload()['context'] as Map;
    expect(PushJournal.hash8(eventId), expected);
    expect(
      context['coverage']['legacy_event_hash'],
      'sha256-${expected.length * 4}',
    );
    expect(context['coverage']['legacy_hash_correlation'], 'approximate');
    expect(context['coverage']['local_shown_semantics'], 'submitted_to_os');
    expect(context['coverage']['os_display'], 'unknown');
  });

  // AC:RL-push-report-outbox/7
  for (final scenario in [
    'matched',
    'mismatch',
    'missing',
    'empty',
    '429',
    'offline',
  ]) {
    test('реальный Sentry HTTP transport: $scenario', () async {
      final store = MemoryPushReportStore();
      String? expected;
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add(request.url.host);
        if (scenario == 'offline') throw const SocketException('offline');
        return http.Response(
          jsonEncode(switch (scenario) {
            'matched' => {'id': expected},
            'mismatch' => {'id': '11111111111111111111111111111111'},
            'empty' => {'id': ''},
            _ => <String, String>{},
          }),
          scenario == '429' ? 429 : 200,
        );
      });
      final box = PushReportOutbox(
        store: store,
        transport: () => SentryPushReportTransport(
          dsn: 'https://public@example.org/1',
          environment: 'test',
          httpClient: client,
        ),
      );
      await box.enqueue(payload(), t0);
      expected =
          ((await box.inspect())['reports'] as List).single['event_id']
              as String;
      expect(await box.drain(t0), scenario == 'matched');
      expect(
        (await box.inspect())['reports'],
        scenario == 'matched' ? isEmpty : hasLength(1),
      );
      expect(requests, ['example.org']);
    });
  }
}
