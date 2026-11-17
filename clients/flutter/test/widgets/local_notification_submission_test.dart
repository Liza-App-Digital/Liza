// ignore_for_file: depend_on_referenced_packages

// ledger:RL-macos-push-collision-observability
// Проверяет настоящий showLocalNotification → plugin.show → BackgroundPush.
// У State подменены только входы: локализованный context, widget и маршрут.
// Его lifecycle намеренно не запускает сетевые сервисы всего приложения.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/background_push.dart';
import 'package:liza/utils/push_helper.dart';
import 'package:liza/utils/push_journal.dart';
import 'package:liza/widgets/local_notifications_extension.dart';
import 'package:liza/widgets/matrix.dart' as liza;

import '../utils/test_client.dart';

const _notifications = MethodChannel(
  'dexterous.com/flutter/local_notifications',
);
const _apns = MethodChannel('com.prodamus.laba.liza/apns');

class _NotificationState extends liza.MatrixState {
  _NotificationState(this._widget, this._context);

  final liza.Matrix _widget;
  final BuildContext _context;

  @override
  liza.Matrix get widget => _widget;

  @override
  BuildContext get context => _context;

  @override
  bool get mounted => _context.mounted;

  @override
  String? get activeRoomId => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Client client;
  late SharedPreferences store;
  late BackgroundPush push;
  late Room room;
  late Completer<void> submitted;
  late List<MethodCall> calls;
  late List<Map<Object?, Object?>> nativeDiagnostics;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await SharedPreferences.getInstance();
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
    room = Room(
      id: '!submission:example.invalid',
      client: client,
      membership: Membership.join,
      notificationCount: 1,
    );
    client.rooms.add(room);
    room.setState(
      Event(
        eventId: r'$sender',
        senderId: '@bob:example.invalid',
        stateKey: '@bob:example.invalid',
        originServerTs: DateTime.now(),
        type: EventTypes.RoomMember,
        content: {'membership': 'join', 'displayname': 'Bob'},
        room: room,
      ),
    );
    FlutterLocalNotificationsPlatform.instance =
        MacOSFlutterLocalNotificationsPlugin();
    submitted = Completer<void>();
    calls = [];
    nativeDiagnostics = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_notifications, (call) async {
      calls.add(call);
      if (call.method == 'show') await submitted.future;
      return null;
    });
    messenger.setMockMethodCallHandler(_apns, (call) async {
      if (call.method == 'recordLocalDiagnostic') {
        nativeDiagnostics.add(
          Map<Object?, Object?>.from(call.arguments as Map),
        );
        return true;
      }
      return false;
    });
    push = BackgroundPush.forTest([client]);
  });

  tearDown(() async {
    if (!submitted.isCompleted) submitted.complete();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_notifications, null);
    messenger.setMockMethodCallHandler(_apns, null);
    await client.dispose(closeDatabase: true);
  });

  Future<_NotificationState> state(WidgetTester tester) async {
    // Future ошибки и его обработчик принадлежат одной зоне testWidgets:
    // Completer из внешнего setUp не переносит ошибки через error-zone.
    submitted = Completer<void>();
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [L10n.delegate],
        supportedLocales: L10n.supportedLocales,
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return _NotificationState(
      liza.Matrix(clients: [client], store: store),
      context,
    )..backgroundPush = push;
  }

  Event event(String id) => Event(
    eventId: id,
    senderId: '@bob:example.invalid',
    originServerTs: DateTime.now(),
    type: EventTypes.Message,
    content: {
      'msgtype': 'm.audio',
      'body': 'private-filename.ogg',
      'org.matrix.msc3245.voice': <String, dynamic>{},
    },
    room: room,
  );

  Future<List<(String, Map<String, String>)>> callback(Event event) async {
    final reports = <(String, Map<String, String>)>[];
    final receivedAt = DateTime.now();
    final outcome = await push.handleApnsMessage(
      {
        'event_id': event.eventId,
        'room_id': room.id,
        'client_name': client.clientName,
      },
      now: receivedAt,
      retract: (_) async => 1,
      deliver: (_) async {},
      report: (reason, tags) => reports.add((reason, tags)),
      journal: PushJournal.forTest(),
    );
    expect(outcome.decision, ApnsBannerDecision.suppressLocal);
    expect(outcome.latency, receivedAt.difference(event.originServerTs));
    return reports;
  }

  List<PushJournalEntry> localEntries(Event event) => PushJournal
      .instance
      .entries
      .where(
        (entry) =>
            entry.eventHash == PushJournal.hash8(event.eventId) &&
            entry.stage == PushStage.local,
      )
      .toList();

  testWidgets(
    'успех plugin.show создаёт submitted с реальными metadata',
    (tester) async {
      final matrix = await state(tester);
      final voice = event(r'$submission-success');
      matrix.showLocalNotification(voice);
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), ['show']);
      expect(push.isLocallyShown(voice.eventId), isTrue);
      expect(
        localEntries(voice),
        isEmpty,
        reason: 'pending резерв не равен принятому ОС уведомлению',
      );

      // ledger:RL-push-native-diagnostics
      // AC:RL-push-native-diagnostics/12 — настоящий ordinary plugin path
      // (unified flag OFF), submission не ждёт ответа диагностического канала.
      expect(nativeDiagnostics.map((entry) => entry['stage']), [
        'localSubmission',
      ]);
      expect(
        nativeDiagnostics.single['requestId'],
        (calls.single.arguments as Map)['id'].toString(),
      );
      expect(nativeDiagnostics.single['media'], 'voice');
      expect(nativeDiagnostics.single['voice'], true);
      expect(nativeDiagnostics.single['eventId'], voice.eventId);
      expect(
        nativeDiagnostics.toString(),
        isNot(contains('private-filename.ogg')),
      );
      submitted.complete();
      await tester.pumpAndSettle();
      expect(nativeDiagnostics.map((entry) => entry['stage']), [
        'localSubmission',
        'localResult',
      ]);
      expect(nativeDiagnostics.last['outcome'], 'accepted');
      expect(localEntries(voice).map((e) => e.reason), [PushReason.shown]);
      final payload = LizaPushPayload.fromString(
        (calls.single.arguments as Map)['payload'] as String,
      );
      expect(payload.clientName, client.clientName);
      expect(payload.eventId, voice.eventId);
      final reports = await callback(voice);
      // AC:RL-macos-push-collision-observability/1
      expect(reports.map((r) => r.$1), ['apns_local_collision']);
      expect(reports.single.$2['push.media_kind'], 'voice');
      expect(reports.single.$2['push.observation'], 'collision_risk');
      expect(reports.toString(), isNot(contains('private-filename.ogg')));
    },
    skip: !Platform.isMacOS,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'pending plugin.show не сообщает об успешной отправке ОС',
    (tester) async {
      final matrix = await state(tester);
      final voice = event(r'$submission-pending');
      matrix.showLocalNotification(voice);
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), ['show']);
      expect(push.isLocallyShown(voice.eventId), isTrue);
      // AC:RL-macos-push-collision-observability/3
      expect(await callback(voice), isEmpty);
      expect(localEntries(voice), isEmpty);
      submitted.complete();
      await tester.pumpAndSettle();
    },
    skip: !Platform.isMacOS,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'ошибка plugin.show оставляет резерв без submitted',
    (tester) async {
      final matrix = await state(tester);
      final voice = event(r'$submission-failed');
      matrix.showLocalNotification(voice);
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), ['show']);
      submitted.completeError(PlatformException(code: 'os-show-failed'));
      await tester.pumpAndSettle();
      expect(localEntries(voice).map((e) => e.reason), [PushReason.failed]);
      expect(nativeDiagnostics.last['outcome'], 'failed');
      // AC:RL-macos-push-collision-observability/3
      expect(await callback(voice), isEmpty);
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isMacOS,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'без BackgroundPush/plugin нет show и записи успешного показа',
    (tester) async {
      final matrix = await state(tester);
      matrix.backgroundPush = null;
      final voice = event(r'$submission-no-plugin');
      matrix.showLocalNotification(voice);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(localEntries(voice), isEmpty);
      expect(push.isLocallyShown(voice.eventId), isFalse);
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isMacOS,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
