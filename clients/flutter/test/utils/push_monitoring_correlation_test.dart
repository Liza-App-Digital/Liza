// ledger:RL-macos-push-collision-observability
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/push_acks.dart';
import 'package:liza/utils/push_event_metadata.dart';
import 'package:liza/utils/push_journal.dart';
import 'package:liza/utils/push_report_outbox.dart';

import 'test_client.dart';
import 'push_report_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AC:RL-macos-push-collision-observability/13
  test('реальный report/outbox сохраняет запись и текущую привязку аккаунта '
      'без raw clientName или содержимого', () async {
    const clientName = 'PRIVATE-LOCAL-CLIENT';
    const eventId = r'$PRIVATE-EVENT';
    final client = await prepareTestClient(
      loggedIn: true,
      clientName: clientName,
    );
    addTearDown(() => client.dispose(closeDatabase: true));
    final now = DateTime.utc(2026, 11, 16, 16);
    final journal = PushJournal.forTest();
    journal.record(
      PushStage.local,
      reason: PushReason.shown,
      eventId: eventId,
      accountName: clientName,
      mediaKind: PushMediaKind.voice,
      relationKind: PushRelationKind.reply,
      relationTargetId: r'$PRIVATE-REPLY',
      source: PushObservationSource.localEvent,
      now: now,
    );
    final entries = journal.entries;
    final accounts = Monitoring.collectPushAccounts([client]);
    expect(accounts.single['account_hash128'], PushJournal.hash128(clientName));
    expect(PushJournal.hash128(eventId), pushAckHash(eventId));
    final context = Monitoring.pushReportContext(
      counters: PushJournalStats.compute(entries, since: now),
      journalTail: PushJournal.tail(entries, Monitoring.pushReportTailBytes),
      journalCoverage: journal.exportCoverage(
        entries,
        Monitoring.pushReportTailBytes,
      ),
      settings: {},
      accounts: accounts,
      nativeJournal: [],
      platform: 'macos',
    );
    expect(
      context['accounts'].single['account_hash128'],
      accounts.single['account_hash128'],
    );
    expect(context['coverage']['dart_journal']['exported_entries'], 1);
    expect(context['coverage']['os_display'], 'unknown');
    final restored = PushJournalEntry.tryParse(context['journal'] as String)!;
    expect(restored.recordId, entries.single.recordId);
    expect(restored.eventHash128, PushJournal.hash128(eventId));
    expect(restored.accountHash128, accounts.single['account_hash128']);
    final directory = await Directory.systemTemp.createTemp(
      'push-correlation-outbox',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/outbox.json');
    PushReportOutbox open() => PushReportOutbox(
      store: FilePushReportStore(file: file),
      transport: () =>
          CallbackPushReportTransport((report) => report['event_id'] as String),
    );
    await open().enqueue({
      'title': Monitoring.pushReportTitle('macos'),
      'tags': <String, String>{},
      'context': context,
    }, now);
    final snapshot = await open().inspect();
    final text = jsonEncode(snapshot);
    expect(text, contains(restored.recordId!));
    expect(text, contains(PushJournal.hash128(eventId)));
    for (final secret in [clientName, eventId, r'$PRIVATE-REPLY']) {
      expect(text, isNot(contains(secret)));
    }
  });

  // AC:RL-macos-push-collision-observability/13
  test(
    'новые account/coverage поля проходят allowlist, произвольные строки нет',
    () {
      final context = Monitoring.pushReportContext(
        counters: {},
        journalTail: '',
        settings: {},
        accounts: [
          {
            'user_id': '@a:test',
            'account_hash128': 'PRIVATE-FILENAME',
            'clientName': 'PRIVATE-CLIENT',
          },
        ],
        nativeJournal: [],
        platform: 'macos',
        journalCoverage: {
          'retained_entries': 'PRIVATE-BODY',
          'exported_entries': -1,
          'tail_truncated': true,
          'raw_payload': 'PRIVATE-TOKEN',
        },
      );
      expect(
        context['accounts'].single.containsKey('account_hash128'),
        isFalse,
      );
      expect(context['coverage']['dart_journal']['tail_truncated'], isTrue);
    expect(context['coverage']['any_source_truncated'], isTrue);
    expect(context['coverage']['truncated'], isFalse,
        reason: 'прежний контракт усечения accounts сохранён');
      expect(
        context['coverage']['dart_journal'].containsKey('retained_entries'),
        isFalse,
      );
      expect(jsonEncode(context), isNot(contains('PRIVATE-')));
    },
  );

  // AC:RL-macos-push-collision-observability/13
  test(
    'media и relations берутся из признаков, APNs не получает relation none',
    () {
      expect(pushMediaKind('m.audio', isVoice: true), PushMediaKind.voice);
      expect(pushMediaKind('m.audio'), PushMediaKind.audio);
      expect(pushMediaKind('m.file', isVoice: true), PushMediaKind.other);
      expect(
        pushApnsMediaKind({
          'type': 'm.room.encrypted',
          'content': {'msgtype': 'm.audio', 'voice': true},
        }),
        PushMediaKind.unknown,
      );
      expect(
        pushApnsMediaKind({'content': '{"msgtype":"m.audio","voice":true}'}),
        PushMediaKind.voice,
      );
      expect(
        pushApnsMediaKind({
          'content': {'body': 'recording.ogg'},
        }),
        PushMediaKind.unknown,
      );
      expect(pushApnsMediaKind({'content': 'invalid'}), PushMediaKind.unknown);
      expect(pushLocalRelation(null).kind, PushRelationKind.none);
      expect(pushLocalRelation('invalid').kind, PushRelationKind.unknown);
      final edit = pushLocalRelation({
        'rel_type': 'm.replace',
        'event_id': r'$target',
      });
      expect(edit.kind, PushRelationKind.replace);
      expect(edit.targetId, r'$target');
      expect(
        pushLocalRelation({
          'm.in_reply_to': {'event_id': r'$reply'},
        }).kind,
        PushRelationKind.reply,
      );
    },
  );
}
