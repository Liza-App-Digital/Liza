// ledger:RL-media-qoe-beacon
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/media_qoe_outbox.dart';
import 'package:liza/utils/media_qoe_reporter.dart';

const _client = <String, Object>{
  'platform': 'macos',
  'os': 'macOS 26.1',
  'model': 'Mac16,1',
  'build': '3815',
  'version': '2.9.0',
};

Map<String, Object> _event(String id, {String outcome = 'success'}) => {
  'attempt_id': id.padLeft(32, '0'),
  'kind': 'view',
  'ts_ms': 1700000000000,
  'outcome': outcome,
  'net': 'wifi',
};

void main() {
  late MemoryMediaQoeStore store;
  late int now;
  late MediaQoeOutbox outbox;

  setUp(() async {
    store = MemoryMediaQoeStore();
    now = 1000000;
    outbox = MediaQoeOutbox(store: store, clock: () => now);
    await outbox.load();
  });

  // load() сериализован с мутациями и после первого раза — no-op: барьер.
  Future<void> flush() => outbox.load();

  group('AC:RL-media-qoe-beacon/5 — хранение', () {
    test('open после рестарта → abandoned_unknown, done — как есть', () async {
      outbox
        ..opened(_event('a', outcome: 'abandoned_unknown'))
        ..opened(_event('b', outcome: 'abandoned_unknown'))
        ..finished(_event('b'));
      await flush();
      expect(outbox.pending, 1, reason: 'open не отправляется до итога');

      final restarted = MediaQoeOutbox(store: store);
      await restarted.load();
      final byId = {
        for (final r in restarted.records)
          (r['e'] as Map)['attempt_id']: (r['e'] as Map)['outcome'],
      };
      expect(byId['a'.padLeft(32, '0')], 'abandoned_unknown');
      expect(byId['b'.padLeft(32, '0')], 'success');
      expect(restarted.pending, 2);
    });

    test('dropped снимает запись целиком', () async {
      outbox
        ..opened(_event('a'))
        ..dropped('a'.padLeft(32, '0'));
      await flush();
      expect(outbox.records, isEmpty);
    });

    test('лимит записей: вытесняются старые', () async {
      for (var i = 0; i < MediaQoeOutbox.maxRecords + 30; i++) {
        outbox.finished(_event('$i'));
      }
      await flush();
      expect(outbox.records, hasLength(MediaQoeOutbox.maxRecords));
      expect(
        (outbox.records.first['e'] as Map)['attempt_id'],
        '30'.padLeft(32, '0'),
      );
    });

    test('лимит байт документа', () async {
      final fat = 'x' * 4000;
      for (var i = 0; i < 100; i++) {
        outbox.finished({..._event('$i'), 'pad': fat});
      }
      await flush();
      expect(store.value!.length, lessThanOrEqualTo(MediaQoeOutbox.maxBytes));
      expect(outbox.records.length, lessThan(100));
    });

    test('битый файл → пустая очередь, не исключение', () async {
      final broken = MemoryMediaQoeStore()..value = '{not json';
      final o = MediaQoeOutbox(store: broken);
      await o.load();
      expect(o.records, isEmpty);
    });
  });

  test(
    'AC:RL-media-qoe-beacon/5 — запись до load() не затирает прошлый запуск',
    () async {
      outbox.opened(_event('old', outcome: 'abandoned_unknown'));
      await flush();

      final restarted = MediaQoeOutbox(store: store);
      restarted.opened(_event('new', outcome: 'abandoned_unknown'));
      await restarted.load();
      final ids = {
        for (final r in restarted.records) (r['e'] as Map)['attempt_id'],
      };
      expect(ids, contains('old'.padLeft(32, '0')));
      expect(ids, contains('new'.padLeft(32, '0')));

      final again = MediaQoeOutbox(store: store);
      await again.load();
      expect(again.records, hasLength(2), reason: 'обе записи в файле');
    },
  );

  group('AC:RL-media-qoe-beacon/6 — отправка и ответы сервера', () {
    test('батч ≤ 50 событий и ≤ 32 КБ; 200 — удаляет', () async {
      for (var i = 0; i < 120; i++) {
        outbox.finished(_event('$i'));
      }
      final sizes = <int>[];
      final accepted = await outbox.drain(_client, (client, events) async {
        sizes.add(events.length);
        final body = jsonEncode({
          'schema': 1,
          'client': client,
          'events': events,
        });
        expect(body.length, lessThanOrEqualTo(32 * 1024));
        return 200;
      });
      expect(accepted, 120);
      expect(sizes, everyElement(lessThanOrEqualTo(50)));
      expect(outbox.pending, 0);
    });

    for (final code in [400, 413]) {
      test('$code — батч выброшен, повтор не нужен', () async {
        outbox.finished(_event('a'));
        var calls = 0;
        await outbox.drain(
          _client,
          (_, _) async => (calls++ == 0) ? code : 200,
        );
        expect(outbox.pending, 0);
        expect(calls, 1);
      });
    }

    for (final code in [401, 403, 404]) {
      test('$code — выброшено и до рестарта не шлём', () async {
        outbox.finished(_event('a'));
        var calls = 0;
        await outbox.drain(_client, (_, _) async {
          calls++;
          return code;
        });
        expect(outbox.disabled, isTrue);
        outbox.finished(_event('b'));
        await outbox.drain(_client, (_, _) async {
          calls++;
          return 200;
        });
        expect(calls, 1);
      });
    }

    for (final code in [429, 500, 503, -1]) {
      test('$code — батч сохранён, бэкофф', () async {
        outbox.finished(_event('a'));
        var calls = 0;
        await outbox.drain(_client, (_, _) async {
          calls++;
          return code;
        });
        expect(outbox.pending, 1);
        await outbox.drain(_client, (_, _) async {
          calls++;
          return 200;
        });
        expect(calls, 1, reason: 'до конца бэкоффа не шлём');
        now += MediaQoeOutbox.minBackoffMs;
        await outbox.drain(_client, (_, _) async {
          calls++;
          return 200;
        });
        expect(calls, 2);
        expect(outbox.pending, 0);
      });
    }

    test('исключение транспорта = сеть: батч сохранён', () async {
      outbox.finished(_event('a'));
      await outbox.drain(_client, (_, _) async => throw StateError('net'));
      expect(outbox.pending, 1);
    });

    test('фон (canSend=false) — не шлём вовсе', () async {
      outbox.finished(_event('a'));
      var calls = 0;
      await outbox.drain(_client, (_, _) async {
        calls++;
        return 200;
      }, canSend: () => false);
      expect(calls, 0);
      expect(outbox.pending, 1);
    });

    test('запись больше батча уходит одна и не держит очередь', () async {
      outbox
        ..finished({..._event('big'), 'pad': 'x' * (40 * 1024)})
        ..finished(_event('small'));
      final batches = <int>[];
      await outbox.drain(_client, (_, events) async {
        batches.add(events.length);
        return events.length == 1 && batches.length == 1 ? 413 : 200;
      });
      expect(batches, [1, 1]);
      expect(outbox.pending, 0);
    });
  });

  test('AC:RL-media-qoe-beacon/6 — тип сети → закрытый enum', () {
    expect(mediaQoeNet([ConnectivityResult.wifi]), 'wifi');
    expect(mediaQoeNet([ConnectivityResult.mobile]), 'mobile');
    expect(
      mediaQoeNet([ConnectivityResult.wifi, ConnectivityResult.vpn]),
      'vpn',
    );
    expect(mediaQoeNet([ConnectivityResult.none]), 'none');
    expect(mediaQoeNet([ConnectivityResult.bluetooth]), 'other');
    expect(mediaQoeNet([]), 'unknown');
  });
}
