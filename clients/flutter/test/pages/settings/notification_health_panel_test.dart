// ignore_for_file: depend_on_referenced_packages
// ledger:RL-push-notification-health-ui
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/background_push.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/notification_health.dart';
import 'package:liza/utils/push_journal.dart';
import 'package:liza/widgets/matrix.dart' as liza;
import 'package:liza/widgets/notification_health_panel.dart';

import '../../utils/test_client.dart';

class _MatrixState extends liza.MatrixState {
  _MatrixState(this.testClient) {
    backgroundPush = BackgroundPush.forTest([testClient]);
  }
  final Client testClient;
  int sent = 0;
  Future<bool> Function()? send;

  @override
  Client get client => testClient;

  @override
  Future<bool> sendPushDiagnostics() async {
    sent++;
    return await send?.call() ?? true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await L10n.delegate.load(const Locale('en'));
    await L10n.delegate.load(const Locale('ru'));
  });
  late Client client;
  late _MatrixState matrix;
  late NotificationHealth health;
  var auth = 1;
  var reads = 0;
  var settingsOpened = 0;
  var settingsResult = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NotificationAuthTracker.resetForTest();
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
    await client.abortSync();
    matrix = _MatrixState(client);
    auth = 1;
    reads = 0;
    settingsOpened = 0;
    settingsResult = true;
    Monitoring.pushReportStatus.value = PushReportStatus.idle;
    health = NotificationHealth(
      platform: 'ios',
      readSettings: () async {
        reads++;
        return {'authorization': auth};
      },
      openSettings: () async {
        settingsOpened++;
        return settingsResult;
      },
    );
  });

  tearDown(() async {
    health.dispose();
    await client.dispose(closeDatabase: true);
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    String locale = 'ru',
    bool compact = false,
    bool twoPanels = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: Locale(locale),
        home: Provider<liza.MatrixState>.value(
          value: matrix,
          child: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  NotificationHealthPanel(health: health, compact: compact),
                  if (twoPanels)
                    NotificationHealthPanel(health: health, compact: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final locale in ['en', 'ru']) {
    testWidgets(
      'AC:RL-push-notification-health-ui/1 $locale: facts, no delivery promise',
      (tester) async {
        await pumpPanel(tester, locale: locale);
        final context = tester.element(find.byType(NotificationHealthPanel));
        final l10n = L10n.of(context);
        expect(find.text(l10n.notificationHealthDenied), findsOneWidget);
        expect(
          find.text(l10n.notificationHealthDeliveryUnknown),
          findsOneWidget,
        );
        expect(find.text(l10n.notificationRegistrationUnknown), findsOneWidget);
        expect(
          find.textContaining(
            locale == 'ru'
                ? 'пользователь выключил'
                : 'push notifications work',
          ),
          findsNothing,
        );
        for (final state in [
          (-1, l10n.notificationHealthUnknown),
          (0, l10n.notificationHealthNotDetermined),
          (2, l10n.notificationHealthAllowed),
          (3, l10n.notificationHealthProvisional),
        ]) {
          auth = state.$1;
          await health.refresh();
          await tester.pump();
          expect(find.text(state.$2), findsOneWidget);
          expect(
            find.text(l10n.notificationHealthDeliveryUnknown),
            findsOneWidget,
          );
        }
        matrix.backgroundPush!.pusherRegisteredByClient[client.clientName] =
            true;
        await health.refresh();
        await tester.pump();
        expect(
          find.text(l10n.notificationRegistrationObserved),
          findsOneWidget,
        );
        matrix.backgroundPush!.pusherRegisteredByClient[client.clientName] =
            false;
        await health.refresh();
        await tester.pump();
        expect(find.text(l10n.notificationRegistrationMissing), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'AC:RL-push-notification-health-ui/2 report statuses and actions',
    (tester) async {
      await pumpPanel(tester);
      final l10n = L10n.of(
        tester.element(find.byType(NotificationHealthPanel)),
      );
      for (final state in [
        (PushReportStatus.idle, l10n.notificationReportIdle),
        (PushReportStatus.pending, l10n.notificationReportPending),
        (PushReportStatus.httpAccepted, l10n.notificationReportAccepted),
        (PushReportStatus.error, l10n.notificationReportError),
        (PushReportStatus.disabled, l10n.notificationReportDisabled),
      ]) {
        Monitoring.pushReportStatus.value = state.$1;
        await tester.pump();
        expect(find.text(state.$2), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('notification-health-send')));
      await tester.pumpAndSettle();
      expect(matrix.sent, 1);
      await tester.tap(
        find.byKey(const ValueKey('notification-health-settings')),
      );
      await tester.pumpAndSettle();
      expect(settingsOpened, 1);
      settingsResult = false;
      await tester.tap(
        find.byKey(const ValueKey('notification-health-settings')),
      );
      await tester.pump();
      expect(find.text(l10n.notificationHealthSettingsFailed), findsOneWidget);
      final previousReads = reads;
      await tester.tap(
        find.byKey(const ValueKey('notification-health-refresh')),
      );
      await tester.pumpAndSettle();
      expect(reads, previousReads + 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'AC:RL-push-notification-health-ui/3 banner only for denied, no dismiss',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpPanel(tester, compact: true);
      expect(
        find.byKey(const ValueKey('notification-health-send')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.close), findsNothing);
      expect(tester.takeException(), isNull);
      for (final next in [-1, 0, 2, 3]) {
        auth = next;
        await health.refresh();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('notification-health-permission')),
          findsNothing,
        );
      }
      auth = 1;
      await health.refresh();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('notification-health-permission')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'AC:RL-push-notification-health-ui/4 one resume observer, no build probe, dispose inflight',
    (tester) async {
      await pumpPanel(tester, twoPanels: true);
      final previousReads = reads;
      Monitoring.pushReportStatus.value = PushReportStatus.pending;
      await tester.pump();
      expect(reads, previousReads);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      auth = 2;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, previousReads + 1);
      expect(
        find.text('Разрешение ОС на уведомления получено'),
        findsOneWidget,
      );
      final pending = Completer<bool>();
      matrix.send = () => pending.future;
      await tester.tap(find.byKey(const ValueKey('notification-health-send')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.complete(true);
      Monitoring.pushReportStatus.value = PushReportStatus.httpAccepted;
      await tester.pumpAndSettle();
      final disposedReads = reads;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(reads, disposedReads);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'AC:RL-push-notification-health-ui/5 failed and late observations stay honest',
    (tester) async {
      health.dispose();
      final observation = Completer<Map<Object?, Object?>?>();
      health = NotificationHealth(
        platform: 'ios',
        readSettings: () => observation.future,
      );
      await pumpPanel(tester);
      expect(
        find.text('Разрешение ОС на уведомления неизвестно'),
        findsOneWidget,
      );
      expect(
        find.text('Нет доступного наблюдения настроек ОС'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      observation.completeError(StateError('probe unavailable'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(health.snapshot.observedAt, isNull);
    },
  );
}
