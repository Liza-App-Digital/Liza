// ignore_for_file: depend_on_referenced_packages

// Страж решения на ПРИХОДЕ APNs-пуша (заявка №31, 2026-09-17). На macOS
// `willPresent` (и гейт в нём) система зовёт только у активного приложения;
// у неактивного опоздавший баннер по уже показанному/прочитанному она рисует
// сама. Поэтому `BackgroundPush.handleApnsMessage` решает по тому же предикату
// в момент прихода и снимает показанный оригинал вдогонку (`retractDelivered`).
//
// Инварианты: снятие — ТОЛЬКО при доказуемо лишнем баннере; дубль onMessage —
// одно решение; телеметрия — наблюдатель (не меняет решение, без ПД в тегах).
//
// ledger:RL-macos-push-late-apns-retract

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/utils/background_push.dart';
import 'package:liza/utils/push_journal.dart';

import 'per_user_fake_api.dart';
import 'test_client.dart';

const _userA = '@nadezhda.rozental:nadezhda.liza.ru';
const _room = '!room:nadezhda.liza.ru';

Future<Client> _client(String name, String userId) {
  final host = userId.split(':').last;
  return prepareTestClient(
    loggedIn: true,
    clientName: name,
    userId: userId,
    homeserver: Uri.parse('https://$host'),
    httpClient: PerUserFakeMatrixApi(userId: userId, homeserverHost: host),
  );
}

Future<void> _syncEvent(
  Client c,
  String roomId,
  String eventId, {
  required int notificationCount,
  DateTime? originServerTs,
}) =>
    c.handleSync(
      SyncUpdate(
        nextBatch: 'b-$eventId',
        rooms: RoomsUpdate(
          join: {
            roomId: JoinedRoomUpdate(
              unreadNotifications: UnreadNotificationCounts(
                notificationCount: notificationCount,
                highlightCount: 0,
              ),
              state: [
                MatrixEvent(
                  type: EventTypes.RoomCreate,
                  eventId: '\$create-$roomId',
                  senderId: c.userID!,
                  originServerTs: DateTime.now(),
                  content: {'creator': c.userID},
                  stateKey: '',
                ),
              ],
              timeline: TimelineUpdate(
                events: [
                  MatrixEvent(
                    type: EventTypes.Message,
                    eventId: eventId,
                    senderId: '@daniel:nadezhda.liza.ru',
                    originServerTs: originServerTs ?? DateTime.now(),
                    content: {'msgtype': 'm.text', 'body': 'привет'},
                  ),
                ],
              ),
            ),
          },
        ),
      ),
    );

Map<String, dynamic> _push(String eventId) => {
      'room_id': _room,
      'event_id': eventId,
      'sender': '@daniel:nadezhda.liza.ru',
    };

/// Подменяемые точки: что позвал `handleApnsMessage`.
class _Probe {
  final retracted = <String>[];
  final delivered = <String>[];
  final reports = <(String, Map<String, String>)>[];
  int? retractMs = 320;

  Future<int?> retract(String eventId) async {
    retracted.add(eventId);
    return retractMs;
  }

  Future<void> deliver(Map<String, dynamic> raw) async {
    delivered.add(raw['event_id'] as String? ?? '');
  }

  void report(String reason, Map<String, String> tags) {
    reports.add((reason, tags));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Client a;
  late BackgroundPush push;
  late _Probe probe;

  setUp(() async {
    a = await _client('Liza-1786629781847', _userA);
    push = BackgroundPush.forTest([a]);
    probe = _Probe();
  });

  tearDown(() async => a.dispose());

  Future<ApnsMessageOutcome> handle(Map<String, dynamic> raw, {DateTime? now}) =>
      push.handleApnsMessage(
        raw,
        now: now,
        retract: probe.retract,
        deliver: probe.deliver,
        report: probe.report,
      );

  // AC:RL-macos-push-late-apns-retract/1
  test('снимаем ТОЛЬКО при доказуемо лишнем баннере: локально показано и '
      'прочитано → retract; непрочитано, неизвестно, без event_id → показ',
      () async {
    // (а) баннер уже нарисован локальным уведомлением
    push.markLocallyShown('\$local');
    var out = await handle(_push('\$local'));
    expect(out.decision, ApnsBannerDecision.suppressLocal);
    expect(probe.retracted, ['\$local']);
    expect(probe.delivered, isEmpty);
    expect(out.retract, 'found:320ms');

    // (б) событие известно, комната прочитана
    await _syncEvent(a, _room, '\$read', notificationCount: 0);
    out = await handle(_push('\$read'));
    expect(out.decision, ApnsBannerDecision.suppressRead);
    expect(probe.retracted, ['\$local', '\$read']);
    expect(probe.delivered, isEmpty);

    // (в) событие известно, комната НЕ прочитана → показать
    await _syncEvent(a, _room, '\$unread', notificationCount: 2);
    out = await handle(_push('\$unread'));
    expect(out.decision, ApnsBannerDecision.show);
    expect(probe.delivered, ['\$unread']);
    expect(probe.retracted.length, 2, reason: 'непрочитанное не снимаем');

    // (г) пуш обогнал sync — событие неизвестно → показать
    out = await handle(_push('\$ahead-of-sync'));
    expect(out.decision, ApnsBannerDecision.unknownEvent);
    expect(probe.delivered, ['\$unread', '\$ahead-of-sync']);
    expect(probe.retracted.length, 2);

    // (д) counts-only без event_id → обычный путь pushHelper
    out = await handle({'room_id': _room});
    expect(out.decision, ApnsBannerDecision.noEvent);
    expect(probe.delivered.length, 3);
    expect(probe.retracted.length, 2);
  }, skip: !Platform.isMacOS);

  // ledger:RL-macos-push-collision-observability
  // AC:RL-macos-push-collision-observability/1
  // AC:RL-macos-push-collision-observability/2
  test('успешная локальная отправка сохраняет возраст и даёт один сигнал '
      'риска пересечения каналов без содержимого сообщения', () async {
    final now = DateTime(2026, 11, 16, 12);
    final reservation = push.markLocallyShown(
      r'$voice',
      originServerTs: now.subtract(const Duration(minutes: 3)),
      clientName: a.clientName,
      msgtype: 'm.audio',
      isVoice: true,
    );
    push.markLocalSubmitted(
      r'$voice',
      reservation: reservation,
      now: now.subtract(const Duration(seconds: 1)),
    );
    final raw = {..._push(r'$voice'), 'client_name': a.clientName};
    final out = await handle(raw, now: now);
    await handle(raw, now: now);
    expect(out.decision, ApnsBannerDecision.suppressLocal);
    expect(out.latency, const Duration(minutes: 3));
    expect(probe.retracted, [r'$voice']);
    expect(probe.reports.map((r) => r.$1), [
      'apns_late_2m',
      'apns_local_collision',
    ]);
    final tags = probe.reports.last.$2;
    expect(tags['push.media_kind'], 'voice');
    expect(tags['push.local_to_callback_ms'], '1000');
    expect(tags['push.observation'], 'collision_risk');
    final values = tags.toString();
    expect(values, isNot(contains(r'$voice')));
    expect(values, isNot(contains(_room)));
    expect(values, isNot(contains(a.clientName)));
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-collision-observability/3
  test('pending, неизвестный аккаунт, другой аккаунт и позднейший submitted '
      'не означают пересечения успешных отправок', () async {
    final now = DateTime(2026, 11, 16, 12);
    for (final scenario in ['pending', 'missing', 'empty', 'other', 'future']) {
      final id = '\$$scenario';
      final reservation = push.markLocallyShown(
        id,
        clientName: scenario == 'empty' ? '' : a.clientName,
        msgtype: 'm.audio',
      );
      if (scenario != 'pending') {
        push.markLocalSubmitted(
          id,
          reservation: reservation,
          now: scenario == 'future'
              ? now.add(const Duration(seconds: 1))
              : now.subtract(const Duration(seconds: 1)),
        );
      }
      await handle({
        ..._push(id),
        if (scenario != 'missing')
          'client_name': switch (scenario) {
            'other' => 'another-client',
            'empty' => '',
            _ => a.clientName,
          },
      }, now: now);
    }
    expect(probe.reports, isEmpty);
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-collision-observability/1
  // AC:RL-macos-push-collision-observability/2
  test('быстрое пересечение тоже наблюдается, тип ограничен закрытым набором',
      () async {
    final now = DateTime(2026, 11, 16, 12);
    for (final (msgtype, isVoice, expected) in [
      ('m.audio', true, 'voice'),
      ('m.audio', false, 'audio'),
      ('m.file', true, 'other'),
      (null, true, 'unknown'),
    ]) {
      final id = '\$$expected';
      final reservation = push.markLocallyShown(
        id,
        originServerTs: now.subtract(const Duration(seconds: 1)),
        clientName: a.clientName,
        msgtype: msgtype,
        isVoice: isVoice,
      );
      push.markLocalSubmitted(id, reservation: reservation, now: now);
      await handle({..._push(id), 'client_name': a.clientName}, now: now);
      expect(probe.reports.last.$1, 'apns_local_collision');
      expect(probe.reports.last.$2['push.media_kind'], expected);
    }
    expect(probe.reports.length, 4);
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-collision-observability/4
  test('дедуп и метаданные вытесняются вместе, повторный резерв не наследует '
      'старую submission', () async {
    final now = DateTime(2026, 11, 16, 12);
    final old = push.markLocallyShown(r'$old', clientName: a.clientName);
    push.markLocalSubmitted(r'$old', reservation: old, now: now);
    for (var i = 0; i < 200; i++) {
      push.markLocallyShown('\$filler$i');
    }
    expect(push.isLocallyShown(r'$old'), isFalse);
    push.markLocalSubmitted(r'$old', reservation: old, now: now);
    push.markLocallyShown(r'$old', clientName: a.clientName);
    await handle({..._push(r'$old'), 'client_name': a.clientName}, now: now);
    expect(probe.reports, isEmpty);
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-collision-observability/5
  test('возраст считается на входе, до ожидания retract', () async {
    final before = DateTime.now();
    push.markLocallyShown(
      r'$wait',
      originServerTs: before,
      clientName: a.clientName,
    );
    final out = await push.handleApnsMessage(
      {..._push(r'$wait'), 'client_name': a.clientName},
      retract: (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return 250;
      },
      deliver: probe.deliver,
      report: probe.report,
    );
    expect(out.latency, isNotNull);
    expect(out.latency!.inMilliseconds, lessThan(200));
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-collision-observability/6
  test(
    'успех старого резерва не подтверждает новый резерв другого аккаунта',
    () async {
      final now = DateTime(2026, 11, 16, 12);
      final old = push.markLocallyShown(
        r'$shared',
        clientName: 'first-account',
      );
      push.markLocallyShown(r'$shared', clientName: a.clientName);
      push.markLocalSubmitted(r'$shared', reservation: old, now: now);
      await handle({
        ..._push(r'$shared'),
        'client_name': a.clientName,
      }, now: now);
      expect(probe.reports, isEmpty);
    },
    skip: !Platform.isMacOS,
  );

  // AC:RL-macos-push-collision-observability/7
  test(
    'submission во время await retract не меняет снимок на входе callback',
    () async {
      final reservation = push.markLocallyShown(
        r'$pending',
        clientName: a.clientName,
      );
      final entered = Completer<void>();
      final release = Completer<int?>();
      final handling = push.handleApnsMessage(
        {..._push(r'$pending'), 'client_name': a.clientName},
        retract: (_) {
          entered.complete();
          return release.future;
        },
        deliver: probe.deliver,
        report: probe.report,
      );
      await entered.future;
      push.markLocalSubmitted(r'$pending', reservation: reservation);
      release.complete(1);
      await handling;
      expect(probe.reports, isEmpty);
    },
    skip: !Platform.isMacOS,
  );

  // AC:RL-macos-push-collision-observability/8
  test(
    'сбой нового collision-репорта не меняет suppress/retract',
    () async {
      final now = DateTime(2026, 11, 16, 12);
      final reservation = push.markLocallyShown(
        r'$failed-report',
        clientName: a.clientName,
      );
      push.markLocalSubmitted(
        r'$failed-report',
        reservation: reservation,
        now: now,
      );
      final out = await push.handleApnsMessage(
        {..._push(r'$failed-report'), 'client_name': a.clientName},
        now: now,
        retract: probe.retract,
        deliver: probe.deliver,
        report: (_, _) => throw StateError('diagnostics unavailable'),
      );
      expect(out.decision, ApnsBannerDecision.suppressLocal);
      expect(out.retract, 'found:320ms');
      expect(probe.retracted, [r'$failed-report']);
      expect(probe.delivered, isEmpty);
    },
    skip: !Platform.isMacOS,
  );

  // AC:RL-macos-push-late-apns-retract/2
  // AC:RL-macos-push-collision-observability/12
  test('связанный журнал переживает исключение retract и сбой отчёта; '
      'типы local и APNs не подменяются друг другом', () async {
    final now = DateTime.utc(2026, 11, 16, 15);
    for (final failing in ['retract', 'report']) {
      final id = '\$$failing-persistent';
      final reservation = push.markLocallyShown(
        id,
        clientName: a.clientName,
        originServerTs: now.subtract(const Duration(minutes: 3)),
        msgtype: 'm.audio',
        isVoice: true,
        relationKind: PushRelationKind.replace,
        relationTargetId: r'$original-private',
      );
      push.markLocalSubmitted(
        id,
        reservation: reservation,
        now: now.subtract(const Duration(seconds: 1)),
      );
      final journal = PushJournal.forTest();
      final handling = push.handleApnsMessage(
        {
          ..._push(id),
          'client_name': a.clientName,
          'type': 'm.room.message',
          'content': {'msgtype': 'm.audio', 'body': 'PRIVATE-FILENAME.ogg'},
        },
        now: now,
        journal: journal,
        retract: (_) async {
          expect(journal.entries.where((e) => e.stage == PushStage.collision),
              hasLength(1), reason: 'collision до первого await retract');
          if (failing == 'retract') throw StateError('retract unavailable');
          return 4;
        },
        deliver: probe.deliver,
        report: (_, _) => throw StateError('report unavailable or throttled'),
      );
      if (failing == 'retract') {
        await expectLater(handling, throwsStateError);
      } else {
        expect((await handling).decision, ApnsBannerDecision.suppressLocal);
      }
      final apns = journal.entries.firstWhere((e) => e.stage == PushStage.apns);
      final collision = journal.entries.singleWhere((e) => e.stage == PushStage.collision);
      expect(apns.eventHash128, PushJournal.hash128(id));
      expect(apns.accountHash128, PushJournal.hash128(a.clientName));
      expect(collision.accountHash128, apns.accountHash128);
      expect(collision.eventHash128, apns.eventHash128);
      expect(apns.mediaKind, PushMediaKind.audio);
      expect(apns.relationKind, PushRelationKind.unknown);
      expect(apns.source, PushObservationSource.apnsPreview);
      expect(collision.mediaKind, PushMediaKind.voice);
      expect(collision.relationKind, PushRelationKind.replace);
      expect(collision.relationTargetHash128, PushJournal.hash128(r'$original-private'));
      expect(collision.value, 1000);
      expect(collision.timeMs, now.millisecondsSinceEpoch);
      final serialized = journal.entries.map((e) => e.toJson()).toString();
      for (final secret in [id, a.clientName, 'PRIVATE-FILENAME', r'$original-private']) {
        expect(serialized, isNot(contains(secret)));
      }
    }
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-late-apns-retract/2
  test('отметка «пришёл нативно» ставится ДО решения — и при подавлении, и '
      'при показе (её читает showLocalNotification из догоняющего sync)',
      () async {
    push.markLocallyShown('\$s');
    await handle(_push('\$s'));
    expect(push.isNativelyReceived('\$s'), isTrue);

    await handle(_push('\$new'));
    expect(push.isNativelyReceived('\$new'), isTrue);
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-late-apns-retract/3
  // Red-proof: без дедупа второй делегат при активном окне давал бы второй
  // pushHelper (двойной haptic) и второе решение.
  test('повторный onMessage по тому же event_id — no-op', () async {
    await _syncEvent(a, _room, '\$dup', notificationCount: 1);
    final first = await handle(_push('\$dup'));
    final second = await handle(_push('\$dup'));

    expect(first.duplicate, isFalse);
    expect(second.duplicate, isTrue);
    expect(probe.delivered, ['\$dup'], reason: 'ровно один pushHelper');
    expect(probe.retracted, isEmpty);
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-late-apns-retract/4
  test('латентность = now − originServerTs известного события; неизвестное → '
      'измерить нечем', () async {
    final now = DateTime(2026, 9, 17, 13, 48, 8);
    await _syncEvent(
      a,
      _room,
      '\$late',
      notificationCount: 0,
      originServerTs: now.subtract(const Duration(minutes: 3)),
    );
    final out = await handle(_push('\$late'), now: now);
    expect(out.latency, const Duration(minutes: 3));

    final unknown = await handle(_push('\$nobody-knows'), now: now);
    expect(unknown.latency, isNull);
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-late-apns-retract/5
  test('в мониторинг — ровно один сигнал при латентности ≥ 120 с и известном '
      'событии; бакеты 2m/5m/15m; ниже порога и для неизвестного — ничего',
      () async {
    final now = DateTime(2026, 9, 17, 13, 48, 8);
    await _syncEvent(
      a,
      _room,
      '\$fast',
      notificationCount: 0,
      originServerTs: now.subtract(const Duration(seconds: 30)),
    );
    await handle(_push('\$fast'), now: now);
    expect(probe.reports, isEmpty, reason: '30 с — не опоздание');

    await _syncEvent(
      a,
      _room,
      '\$late',
      notificationCount: 0,
      originServerTs: now.subtract(const Duration(minutes: 24)),
    );
    await handle(_push('\$late'), now: now);
    expect(probe.reports.length, 1);
    expect(probe.reports.single.$1, 'apns_late_15m');

    await handle(_push('\$unknown'), now: now);
    expect(probe.reports.length, 1, reason: 'неизвестное событие не меряем');

    expect(BackgroundPush.apnsLateReason(const Duration(seconds: 119)), isNull);
    expect(BackgroundPush.apnsLateReason(const Duration(seconds: 120)),
        'apns_late_2m');
    expect(BackgroundPush.apnsLateReason(const Duration(minutes: 7)),
        'apns_late_5m');
    expect(BackgroundPush.apnsLateReason(const Duration(minutes: 15)),
        'apns_late_15m');
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-late-apns-retract/6
  test('теги сигнала без room_id / event_id / mxid', () async {
    final now = DateTime(2026, 9, 17, 13, 48, 8);
    await _syncEvent(
      a,
      _room,
      '\$secret-event',
      notificationCount: 0,
      originServerTs: now.subtract(const Duration(minutes: 3)),
    );
    await handle(_push('\$secret-event'), now: now);

    final (reason, tags) = probe.reports.single;
    final everything = [reason, ...tags.keys, ...tags.values].join(' ');
    expect(everything, isNot(contains(_room)));
    expect(everything, isNot(contains('secret-event')));
    expect(everything, isNot(contains('@')));
    expect(tags['push.decision'], 'suppressRead');
    expect(tags['push.latency_s'], '180');
    expect(tags['push.retract'], 'found:320ms');
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-late-apns-retract/7
  test('телеметрия — наблюдатель: её сбой не меняет решение и не отменяет '
      'снятие', () async {
    final now = DateTime(2026, 9, 17, 13, 48, 8);
    await _syncEvent(
      a,
      _room,
      '\$boom',
      notificationCount: 0,
      originServerTs: now.subtract(const Duration(minutes: 3)),
    );
    final out = await push.handleApnsMessage(
      _push('\$boom'),
      now: now,
      retract: probe.retract,
      deliver: probe.deliver,
      report: (_, _) => throw StateError('sentry down'),
    );

    expect(out.decision, ApnsBannerDecision.suppressRead);
    expect(out.retract, 'found:320ms');
    expect(probe.retracted, ['\$boom']);
  }, skip: !Platform.isMacOS);

  // AC:RL-macos-push-late-apns-retract/8
  test('натив не нашёл показанного (retract=null) → честный not-found, без '
      'повторного показа', () async {
    probe.retractMs = null;
    push.markLocallyShown('\$gone');
    final out = await handle(_push('\$gone'));

    expect(out.retract, 'not-found');
    expect(probe.delivered, isEmpty);
  }, skip: !Platform.isMacOS);
  // AC:RL-macos-push-late-apns-retract/12
  test('исход retract пишется в журнал при suppressLocal и suppressRead: '
      'found:<мс> / missed, без retract-записи при show', () async {
    final jr = PushJournal.forTest();
    Future<void> run(String id, int? ms) async {
      probe.retractMs = ms;
      await push.handleApnsMessage(
        _push(id),
        retract: probe.retract,
        deliver: probe.deliver,
        report: probe.report,
        journal: jr,
      );
    }

    push.markLocallyShown('\$l1');
    await run('\$l1', 280);
    push.markLocallyShown('\$l2');
    await run('\$l2', null);
    await _syncEvent(a, _room, '\$u1', notificationCount: 1);
    await run('\$u1', 100);

    final r = jr.entries.where((e) => e.stage == PushStage.retract).toList();
    expect(r.map((e) => e.reason), [
      PushReason.retractFound,
      PushReason.retractMissed,
    ]);
    expect(r.first.value, 280);
    expect(r.last.value, isNull);
  }, skip: !Platform.isMacOS);
}
