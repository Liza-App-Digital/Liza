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
