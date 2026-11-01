// ignore_for_file: depend_on_referenced_packages
//
// Страж RL-push-rules-default-reset-client: экран «Настройки → Уведомления».
//   • обычный пользователь НЕ видит сырых переключателей правил Matrix (у
//     `suppress_*` смысл инвертирован — именно ими выключили доставку в
//     инциденте 2026-09-14), но видит «Отключить все уведомления»;
//   • при отклонении дефолтных правил — предупреждение и «Сбросить к
//     стандартным», которое сбрасывает ровно отклонения;
//   • разработчик видит сырые правила как раньше.
// Рендерит РЕАЛЬНЫЙ SettingsNotificationsView через Matrix.of(context).
// ledger:RL-push-rules-default-reset-client
// ledger:RL-push-notification-health-ui

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/settings_notifications/settings_notifications.dart';
import 'package:liza/pages/settings_notifications/settings_notifications_view.dart';
import 'package:liza/utils/push_rule_defaults.dart';
import 'package:liza/utils/notification_health.dart';
import 'package:liza/utils/user_role_service.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client, this._roleService);

  final Client _client;
  final UserRoleService _roleService;

  @override
  Client get client => _client;

  @override
  UserRoleService get userRoleService => _roleService;
}

class _RecordingController extends SettingsNotificationsController {
  List<DefaultPushRule>? resetWith;

  @override
  Future<void> resetPushRulesToDefault(List<DefaultPushRule> deviations) async {
    resetWith = deviations;
  }
}

Map<String, Object?> _rule(String id, bool enabled) => {
  'rule_id': id,
  'default': true,
  'enabled': enabled,
  'actions': <Object?>[],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await L10n.delegate.load(const Locale('en'));
    await L10n.delegate.load(const Locale('ru'));
  });
  late Client client;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          NotificationHealth.appleChannel,
          (call) async => null,
        );
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
    await client.abortSync();
    // client.init асинхронно подгружает account data из БД и ЗАМЕНЯЕТ карту
    // целиком — подложенные до этого правила молча исчезли бы.
    await client.accountDataLoading;
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  Future<_RecordingController> pumpScreen(
    WidgetTester tester, {
    required bool messageEnabled,
    required bool suppressEditsEnabled,
    String role = 'user',
    String locale = 'ru',
  }) async {
    client.accountData['m.push_rules'] = BasicEvent(
      type: 'm.push_rules',
      content: {
        'global': {
          'override': [
            _rule('.m.rule.master', false),
            _rule('.m.rule.suppress_edits', suppressEditsEnabled),
            _rule('.m.rule.reaction', true),
          ],
          'underride': [_rule('.m.rule.message', messageEnabled)],
        },
      },
    );
    final service = UserRoleService(() => client);
    service.applyToDeviceEvent(client.userID!, {'code': role, 'label': role});
    final controller = _RecordingController();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: Locale(locale),
        home: Provider<liza_matrix.MatrixState>.value(
          value: _TestMatrixState(client, service),
          child: SettingsNotificationsView(controller),
        ),
      ),
    );
    // L10n-делегаты грузятся асинхронно: одного pump мало, home ещё не построен.
    await tester.pumpAndSettle();
    return controller;
  }

  final resetButton = find.byKey(const ValueKey('push-rules-reset-to-default'));

  testWidgets(
    'AC:RL-push-rules-default-reset-client/4 — user: сырых переключателей нет, master есть',
    (tester) async {
      await pumpScreen(
        tester,
        messageEnabled: true,
        suppressEditsEnabled: true,
      );
      expect(find.text('Отключить все уведомления'), findsOneWidget);
      expect(find.text('Сообщение'), findsNothing);
      expect(find.text('Подавление правки'), findsNothing);
      expect(find.byType(Switch), findsOneWidget);
      expect(resetButton, findsNothing);
    },
  );

  testWidgets(
    'AC:RL-push-rules-default-reset-client/4 — developer: сырые правила видны',
    (tester) async {
      await pumpScreen(
        tester,
        messageEnabled: true,
        suppressEditsEnabled: true,
        role: 'developer',
      );
      expect(find.text('Сообщение'), findsOneWidget);
      expect(find.text('Подавление правки'), findsOneWidget);
      expect(find.text('Отключить все уведомления'), findsOneWidget);
    },
  );

  testWidgets(
    'AC:RL-push-rules-default-reset-client/3 — отклонение: предупреждение + сброс ровно отклонений',
    (tester) async {
      final controller = await pumpScreen(
        tester,
        messageEnabled: false,
        suppressEditsEnabled: false,
      );
      expect(
        find.text('Уведомления настроены не по умолчанию'),
        findsOneWidget,
      );
      expect(resetButton, findsOneWidget);
      await tester.ensureVisible(resetButton);
      await tester.tap(resetButton);
      await tester.pump();
      expect(controller.resetWith!.map((r) => r.ruleId), [
        '.m.rule.message',
        '.m.rule.suppress_edits',
      ]);
    },
  );
  for (final locale in ['en', 'ru']) {
    testWidgets(
      'AC:RL-push-notification-health-ui/6 $locale local notification is not end-to-end',
      (tester) async {
        await pumpScreen(
          tester,
          messageEnabled: true,
          suppressEditsEnabled: true,
          role: 'developer',
          locale: locale,
        );
        final l10n = L10n.of(
          tester.element(find.byType(SettingsNotificationsView)),
        );
        expect(find.text(l10n.testPushNotification), findsOneWidget);
        expect(
          find.text(l10n.notificationLocalTestExplanation),
          findsOneWidget,
        );
        expect(find.textContaining('APNs/FCM'), findsOneWidget);
      },
    );
  }
}
