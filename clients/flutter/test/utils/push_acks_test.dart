// ledger:RL-push-device-acks
// ledger:RL-push-test-sender-and-acks
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/notification_health.dart';
import 'package:liza/utils/push_acks.dart';
import 'package:liza/utils/push_journal.dart';

void main() {
  final now = DateTime.utc(2026, 11, 12, 12);
  final since = now.subtract(const Duration(hours: 24));
  int at(Duration ago) => now.subtract(ago).millisecondsSinceEpoch;

  test('AC:RL-push-device-acks/1 хэш совпадает с _push_outcomes.py Sygnal', () {
    // hashlib.sha256('$abc:liza.ru'.encode()).hexdigest()[:32]
    expect(pushAckHash(r'$abc:liza.ru'), '8280ccde4075526c8ab8c53c4333f2db');
    expect(pushAckHash('pk-token-1'), '235b5a3effd707d8475a7db7322ac46b');
  });

  test('AC:RL-push-device-acks/2 в подтверждении только разрешённые поля, '
      'без сырых идентификаторов', () {
    final block = buildPushAcks(
      nativeJournal: [
        {
          'id': 'x',
          't': at(const Duration(minutes: 5)),
          's': 'nseReceived',
          'event_hash': pushAckHash(r'$e1:liza.ru'),
        },
        {
          'id': 'y',
          't': at(const Duration(minutes: 4)),
          's': 'token',
          'reason': 'rotated',
        },
      ],
      local: [
        {
          'e': pushAckHash(r'$e2:liza.ru'),
          'o': 'shown',
          't': at(const Duration(minutes: 3)),
        },
      ],
      pushkey: 'pk-token-1',
      build: '3800',
      since: since,
    );
    expect(block.keys.toSet(), {
      'schema',
      'hash_version',
      'pushkey_hash',
      'build',
      'acks',
      'truncated',
    });
    expect(block['pushkey_hash'], '235b5a3effd707d8475a7db7322ac46b');
    final acks = block['acks'] as List;
    expect(acks, hasLength(2), reason: 'token — не подтверждение доставки');
    for (final a in acks.cast<Map>()) {
      expect(a.keys.toSet(), {'e', 'o', 'src', 't'});
    }
    final json = jsonEncode(block);
    expect(json, isNot(contains('pk-token-1')));
    expect(json, isNot(contains(r'$e1')));
    expect(json, isNot(contains('liza.ru')));
  });

  test('AC:RL-push-device-acks/3 окно 24 ч, новейшие первыми, объём ограничен '
      'с честным счётчиком', () {
    final local = [
      for (var i = 0; i < 250; i++)
        {
          'e': pushAckHash('\$e$i'),
          'o': 'shown',
          't': at(Duration(seconds: 250 - i)),
        },
      {
        'e': pushAckHash(r'$old'),
        'o': 'shown',
        't': at(const Duration(hours: 25)),
      },
    ];
    final block = buildPushAcks(
      nativeJournal: const [],
      local: local,
      pushkey: null,
      build: '3800',
      since: since,
    );
    final acks = (block['acks'] as List).cast<Map>();
    expect(acks, hasLength(200));
    expect(block['truncated'], 50);
    expect(acks.first['e'], pushAckHash(r'$e249'));
    expect(acks.any((a) => a['e'] == pushAckHash(r'$old')), isFalse);
    expect(block.containsKey('pushkey_hash'), isFalse);
  });

  test(
    'AC:RL-push-device-acks/4 исходы: нативные стадии и локальный показ',
    () {
      expect(nativeAckOutcome('nseCompleted'), PushAckOutcome.shown);
      expect(nativeAckOutcome('fcmReceived'), PushAckOutcome.received);
      expect(nativeAckOutcome('fcmDuplicate'), PushAckOutcome.duplicate);
      expect(nativeAckOutcome('nseSuppressed'), PushAckOutcome.suppressed);
      expect(nativeAckOutcome('nseSwept'), isNull);
      expect(nativeAckOutcome('token'), isNull);
      expect(localAckOutcome(PushReason.shown), PushAckOutcome.shown);
      expect(localAckOutcome(PushReason.apnsHandled), PushAckOutcome.skipped);
      expect(localAckOutcome(PushReason.failed), PushAckOutcome.failed);
      expect(localAckOutcome(PushReason.activeRoom), isNull);
      // Нативный журнал на стороне Dart не отбрасывает новые стадии.
      final kept = NativePushDiagnostics.sanitize([
        {
          'id': '00000000-0000-4000-8000-000000000001',
          't': now.millisecondsSinceEpoch,
          's': 'fcmDuplicate',
          'event_hash': pushAckHash(r'$e1'),
        },
      ], now: now);
      expect(kept.single['s'], 'fcmDuplicate');
    },
  );

  test(
    'AC:RL-push-device-acks/5 кольцо локальных исходов персистентно и ограничено',
    () async {
      SharedPreferences.setMockInitialValues({
        'push.acks_v1': jsonEncode([
          {'e': 'not-a-hash', 'o': 'shown', 't': 1},
          {'e': pushAckHash('a'), 'o': 'bogus', 't': 1},
        ]),
      });
      final log = PushAckLog.instance;
      for (var i = 0; i < 205; i++) {
        log.record('\$e$i', PushAckOutcome.shown, now: now);
      }
      log.record('', PushAckOutcome.shown, now: now);
      final read = await log.read();
      expect(read, hasLength(PushAckLog.maxEntries));
      expect(read.last['e'], pushAckHash(r'$e204'));
      expect(read.every((a) => (a['e'] as String).length == 32), isTrue);
    },
  );

  test('AC:RL-push-device-acks/6 блок acks уходит в push-report только если '
      'передан', () {
    Map<String, dynamic> ctx({Map<String, Object>? acks}) =>
        Monitoring.pushReportContext(
          counters: const {},
          journalTail: '',
          settings: const {},
          accounts: const [],
          nativeJournal: const [],
          platform: 'ios',
          acks: acks,
        );
    expect(ctx().containsKey('acks'), isFalse);
    final block = buildPushAcks(
      nativeJournal: const [],
      local: const [],
      pushkey: 'pk-token-1',
      build: '3800',
      since: since,
    );
    expect(ctx(acks: block)['acks'], block);
  });

  test('AC:RL-push-test-sender-and-acks/9 момент отправки Sygnal (sent) '
      'проходит sanitize нативного журнала и попадает в подтверждение как s', () {
    final journal = NativePushDiagnostics.sanitize([
      {
        'id': '00000000-0000-4000-8000-000000000002',
        't': now.millisecondsSinceEpoch,
        's': 'fcmReceived',
        'event_hash': pushAckHash(r'$e1'),
        'sent': now.millisecondsSinceEpoch - 1400,
      },
      {
        'id': '00000000-0000-4000-8000-000000000003',
        't': now.millisecondsSinceEpoch,
        's': 'nseCompleted',
        'event_hash': pushAckHash(r'$e2'),
        'sent': 'soon',
      },
    ], now: now);
    final block = buildPushAcks(
      nativeJournal: journal,
      local: const [],
      pushkey: null,
      build: '3800',
      since: since,
    );
    final acks = (block['acks'] as List).cast<Map<String, Object>>();
    expect(
      acks.firstWhere((a) => a['e'] == pushAckHash(r'$e1'))['s'],
      now.millisecondsSinceEpoch - 1400,
    );
    expect(
      acks.firstWhere((a) => a['e'] == pushAckHash(r'$e2')).containsKey('s'),
      isFalse,
    );
  });
}
