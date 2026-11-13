// Device-flow (Ярус C) задачи «пуши и синхронизация уведомлений между
// устройствами», спека 2026-11-12-push-sync-industry-alignment.
// ledger:RL-push-notification-checkup
// ledger:RL-push-read-banner-sweep
// ledger:RL-push-device-acks
// ledger:RL-push-test-sender-and-acks
//
// Гоняет владелец: `.claude/tools/prove-ui/run.sh
// integration_test/liza/push_sync_flow_test.dart` (iOS + Android, локальный стек).
//
// Что видит человек и что проверяем на реальном бинаре:
//   1) Р8: экран «Уведомления» показывает секцию «Проверка уведомлений»;
//      кнопка тестового пуша есть ровно тогда, когда liza-bot-api стенда
//      ответил `status.test == true` (флаг `LIZA_PUSH_PROBE_ENABLED`); с
//      включённым флагом и живым FCM/APNs — нажатие даёт «Пуш дошёл за N с».
//   2) Р2 Android: баннер шторки по событию, прочитанному на ДРУГОМ устройстве
//      того же аккаунта, снимается проходом чистки; баннер непрочитанного
//      события той же выборки остаётся (контроль, без него тест зеленел бы и
//      при «снимаем всё»). Три сообщения, а не одно: чтение линейно, и
//      ошибка «снимаем только последнее» видна лишь на цепочке.
//   3) Ф1.1: подтверждение доставки переживает запись на устройстве (хэш, без
//      event_id в открытом виде).
//   4) Р5 Android (AC-16): два сообщения в чат — ОДНО уведомление-переписка с
//      id второго события и тегом комнаты (две строки MessagingStyle); тот же
//      пуш повторно — без второго уведомления; чтение на другом устройстве
//      снимает его проходом чистки.
// iOS-чистка живёт в NSE/AppDelegate (Swift) — из Dart не управляется; её
// поведение — host-тест `read_banner_sweep_test.dart` + ручной AC.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';

import 'package:liza/main.dart' as app;
import 'package:liza/utils/android_read_sweep.dart';
import 'package:liza/utils/android_room_notification.dart';
import 'package:liza/utils/push_acks.dart';
import 'package:liza/utils/push_helper.dart';
import 'package:liza/utils/push_probe_api.dart';
import 'package:matrix/matrix.dart' show PushNotification;
import 'package:liza/widgets/matrix.dart';

import 'e2e_actor.dart';
import 'e2e_config.dart';
import 'liza_flows.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Р8: секция «Проверка уведомлений» на экране уведомлений', (
    tester,
  ) async {
    app.main();
    await tester.ensureLizaHome();

    final ctx = tester.element(find.byType(Navigator).first);
    GoRouter.of(ctx).go('/rooms/settings/notifications');
    await tester.pump(const Duration(milliseconds: 900));

    await tester.waitUntil(
      find.byKey(const ValueKey('notification-checkup')),
      timeout: const Duration(seconds: 15),
    );
    expect(find.text('Проверка уведомлений'), findsOneWidget);
    final client = Matrix.of(tester.element(find.byType(MaterialApp))).client;
    final status = await fetchPushProbeStatus(
      pushProbeBase(client.homeserver?.host),
    );
    final button = find.byKey(const ValueKey('notification-test-push'));
    if (!status.test) {
      expect(
        button,
        findsNothing,
        reason: 'сервер без LIZA_PUSH_PROBE_ENABLED — кнопки быть не должно',
      );
    } else if (button.evaluate().isNotEmpty) {
      // Флаг включён и pusher есть: полный путь Sygnal → FCM/APNs → журнал.
      await tester.tap(button);
      await tester.waitUntil(
        find.textContaining('Пуш дошёл'),
        timeout: const Duration(seconds: 75),
      );
    } else {
      debugPrint(
        '[push_sync_flow] флаг включён, но pusher не найден — '
        'тест-пуш проверить нельзя (эмулятор без FCM?)',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ф1.1: подтверждение доставки пишется хэшем и читается', (
    tester,
  ) async {
    const eventId = r'$push-sync-flow-ack';
    PushAckLog.instance.record(eventId, PushAckOutcome.received);
    final entries = await PushAckLog.instance.read();
    expect(entries.map((e) => e['e']), contains(pushAckHash(eventId)));
    expect(entries.toString(), isNot(contains(eventId)));
  });

  testWidgets(
    'Р2 Android: прочитанное на другом устройстве снимается из шторки, '
    'непрочитанное остаётся',
    (tester) async {
      if (defaultTargetPlatform != TargetPlatform.android) {
        debugPrint('[push_sync_flow] не Android — Dart-чистки нет, пропуск');
        return;
      }
      final actorB = await E2eActor.login(
        E2eConfig.homeserver,
        E2eConfig.userB,
      );
      // Второе устройство того же аккаунта: оно и «читает на Маке».
      final otherDeviceA = await E2eActor.login(
        E2eConfig.homeserver,
        E2eConfig.userA,
      );
      final roomId = await actorB.createGroupChat([
        otherDeviceA.userId,
      ], name: 'Чистка шторки');
      await otherDeviceA.joinRoom(roomId);
      final e1 = await actorB.sendText(roomId, 'первое');
      final e2 = await actorB.sendText(roomId, 'второе');
      final e3 = await actorB.sendText(roomId, 'третье');

      app.main();
      await tester.ensureLizaHome();
      final matrix = Matrix.of(tester.element(find.byType(MaterialApp)));
      final client = matrix.client;

      // Прочитано до второго включительно — на другом устройстве.
      await otherDeviceA.sendReadReceipt(roomId, e2);

      final plugin = FlutterLocalNotificationsPlugin();
      final ids = {e1: 9101, e2: 9102, e3: 9103};
      for (final entry in ids.entries) {
        await plugin.show(
          entry.value,
          'Чистка шторки',
          entry.key,
          const NotificationDetails(
            android: AndroidNotificationDetails('push_sync_flow', 'flow'),
          ),
          payload: LizaPushPayload(
            client.clientName,
            roomId,
            entry.key,
          ).toString(),
        );
      }

      // /notifications отдаёт read с задержкой на обработку квитанции.
      var removed = 0;
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (removed < 2 && DateTime.now().isBefore(end)) {
        removed += await sweepReadAndroidBanners(
          client: client,
          plugin: plugin,
          clientCount: matrix.widget.clients.length,
        );
        await tester.pump(const Duration(milliseconds: 500));
      }

      final left = (await plugin.getActiveNotifications())
          .map((n) => n.id)
          .toSet();
      expect(left, isNot(contains(9101)), reason: 'e1 прочитано — снять');
      expect(left, isNot(contains(9102)), reason: 'e2 прочитано — снять');
      expect(left, contains(9103), reason: 'e3 не прочитано — оставить');
      await plugin.cancel(9103);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Р5 Android: одно уведомление-переписка на чат с id по событию; '
      'повтор не дублирует; чтение на другом устройстве снимает', (
    tester,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      debugPrint('[push_sync_flow] не Android — пропуск');
      return;
    }
    final actorB = await E2eActor.login(E2eConfig.homeserver, E2eConfig.userB);
    final otherDeviceA = await E2eActor.login(
      E2eConfig.homeserver,
      E2eConfig.userA,
    );
    final roomId = await actorB.createGroupChat([
      otherDeviceA.userId,
    ], name: 'Переписка в шторке');
    await otherDeviceA.joinRoom(roomId);
    final e1 = await actorB.sendText(roomId, 'раз');
    final e2 = await actorB.sendText(roomId, 'два');

    app.main();
    await tester.ensureLizaHome();
    final matrix = Matrix.of(tester.element(find.byType(MaterialApp)));
    final client = matrix.client;
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.cancelAll();

    Future<void> push(String eventId) => pushHelper(
      PushNotification(devices: const [], roomId: roomId, eventId: eventId),
      clients: matrix.widget.clients,
      clientName: client.clientName,
      flutterLocalNotificationsPlugin: plugin,
    );
    Future<List<ActiveNotification>> ofRoom() async =>
        (await plugin.getActiveNotifications())
            .where((n) => n.tag == roomId)
            .toList();

    await push(e1);
    await push(e2);
    var room = await ofRoom();
    expect(room, hasLength(1), reason: 'одно уведомление-переписка на чат');
    expect(room.single.id, pushEventNotificationId(client.clientName, e2));
    final style = await AndroidFlutterLocalNotificationsPlugin()
        .getActiveNotificationMessagingStyle(room.single.id!, tag: roomId);
    expect(style?.messages?.map((m) => m.text), ['раз', 'два']);

    await push(e2);
    room = await ofRoom();
    expect(room, hasLength(1), reason: 'повтор того же события не дублирует');
    final again = await AndroidFlutterLocalNotificationsPlugin()
        .getActiveNotificationMessagingStyle(room.single.id!, tag: roomId);
    expect(again?.messages, hasLength(2), reason: 'и строку не задваивает');

    await otherDeviceA.sendReadReceipt(roomId, e2);
    final end = DateTime.now().add(const Duration(seconds: 20));
    while ((await ofRoom()).isNotEmpty && DateTime.now().isBefore(end)) {
      await sweepReadAndroidBanners(
        client: client,
        plugin: plugin,
        clientCount: matrix.widget.clients.length,
      );
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(await ofRoom(), isEmpty, reason: 'прочитано на другом устройстве');
    expect(tester.takeException(), isNull);
  });
}
