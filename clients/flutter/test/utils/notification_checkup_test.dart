// ignore_for_file: depend_on_referenced_packages
// ledger:RL-push-notification-checkup
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/background_push.dart';
import 'package:liza/utils/notification_checkup.dart';
import 'package:liza/utils/notification_health.dart';
import 'package:liza/utils/push_acks.dart';
import 'package:liza/utils/push_probe_api.dart';
import 'package:liza/utils/test_push_probe.dart';
import 'package:liza/widgets/matrix.dart' as liza;
import 'package:liza/widgets/notification_checkup_section.dart';

import 'test_client.dart';

const _key = 'PUSHKEY-OWN';

Pusher _pusher(String pushkey, String appId, {String device = 'iPhone'}) =>
    Pusher(
      appId: appId,
      pushkey: pushkey,
      appDisplayName: 'Liza',
      data: PusherData(url: Uri.parse('https://push.example/_matrix/push/v1')),
      deviceDisplayName: device,
      kind: 'http',
      lang: 'ru',
    );

PushRule _rule(String id, bool enabled) =>
    PushRule(actions: const [], default$: true, enabled: enabled, ruleId: id);

PushRuleSet _rules({
  bool master = false,
  bool message = true,
  bool suppressEdits = true,
}) => PushRuleSet(
  override: [
    _rule('.m.rule.master', master),
    _rule('.m.rule.suppress_edits', suppressEdits),
    _rule('!room:example.com', false),
  ],
  underride: [_rule('.m.rule.message', message)],
);

List<CheckupFinding> _eval({
  String platform = 'ios',
  Map<String, String> tags = const {'liza.auth': 'authorized'},
  List<Pusher>? pushers,
  String? pushkey = _key,
  PushRuleSet? rules,
  bool needsUpdate = false,
}) => evaluateNotificationCheckup(
  platform: platform,
  tags: tags,
  pushers: pushers ?? [_pusher(_key, 'ru.prodamus.liza')],
  pushkey: pushkey,
  pushRules: rules ?? _rules(),
  needsUpdate: needsUpdate,
);

Set<CheckupIssue> _issues(List<CheckupFinding> f) => {
  for (final x in f) x.issue,
};

class _MatrixState extends liza.MatrixState {
  _MatrixState(this.testClient) {
    backgroundPush = BackgroundPush.forTest([testClient])..lastPushkey = _key;
  }
  final Client testClient;

  @override
  Client get client => testClient;
}

void main() {
  group('evaluateNotificationCheckup', () {
    test('AC:RL-push-notification-checkup/1 permission and hidden alerts '
        'per platform; unknown is not a problem', () {
      for (final platform in ['ios', 'macos', 'android']) {
        expect(
          _eval(platform: platform, tags: {'liza.auth': 'denied'}),
          contains(
            const CheckupFinding(
              CheckupIssue.permissionDenied,
              CheckupAction.openSettings,
            ),
          ),
          reason: platform,
        );
        for (final auth in ['unknown', 'unsupported', 'not_determined']) {
          expect(
            _issues(_eval(platform: platform, tags: {'liza.auth': auth})),
            isNot(
              anyOf(
                contains(CheckupIssue.permissionDenied),
                contains(CheckupIssue.alertsHidden),
              ),
            ),
            reason: '$platform/$auth',
          );
        }
      }
      for (final platform in ['ios', 'macos']) {
        for (final tags in [
          {'liza.auth': 'authorized', 'liza.alert': 'disabled'},
          {'liza.auth': 'provisional', 'liza.alert_style': 'none'},
        ]) {
          expect(
            _issues(_eval(platform: platform, tags: tags)),
            contains(CheckupIssue.alertsHidden),
            reason: '$platform $tags',
          );
        }
        expect(
          _issues(
            _eval(
              platform: platform,
              tags: {'liza.auth': 'authorized', 'liza.alert': 'enabled'},
            ),
          ),
          isNot(contains(CheckupIssue.alertsHidden)),
        );
      }
      for (final importance in ['none', 'missing']) {
        expect(
          _issues(
            _eval(
              platform: 'android',
              tags: {
                'liza.auth': 'authorized',
                'liza.channel_importance': importance,
              },
            ),
          ),
          contains(CheckupIssue.alertsHidden),
        );
      }
      expect(
        _issues(
          _eval(
            platform: 'android',
            tags: {
              'liza.auth': 'authorized',
              'liza.channel_importance': 'high',
            },
          ),
        ),
        isNot(contains(CheckupIssue.alertsHidden)),
      );
      // Денайд не дублируется «скрытыми баннерами».
      expect(
        _issues(_eval(tags: {'liza.auth': 'denied', 'liza.alert': 'disabled'})),
        isNot(contains(CheckupIssue.alertsHidden)),
      );
    });

    test('AC:RL-push-notification-checkup/2 own pusher missing, second copy '
        'only across Apple accounts, unknown pushers stay silent', () {
      expect(
        _eval(pushers: [_pusher('OTHER', 'ru.prodamus.liza')]),
        contains(
          const CheckupFinding(
            CheckupIssue.pusherMissing,
            CheckupAction.reconnect,
          ),
        ),
      );
      expect(
        _issues(_eval(pushers: const [])),
        contains(CheckupIssue.pusherMissing),
      );
      for (final pushkey in [null, '']) {
        expect(
          _issues(_eval(pushkey: pushkey, pushers: const [])),
          isNot(contains(CheckupIssue.pusherMissing)),
        );
      }
      expect(
        _issues(
          evaluateNotificationCheckup(
            platform: 'ios',
            tags: const {},
            pushers: null,
            pushkey: _key,
            pushRules: null,
            needsUpdate: false,
          ),
        ),
        isEmpty,
      );

      final twin = _eval(
        pushers: [
          _pusher(_key, 'ru.prodamus.liza'),
          _pusher('OLD', 'com.prodamus.laba.liza'),
        ],
      );
      expect(
        twin,
        contains(
          const CheckupFinding(CheckupIssue.secondCopy, CheckupAction.none),
        ),
      );
      // Тот же аккаунт Apple (data_message-копия) и другое устройство — не «вторая копия».
      for (final other in [
        _pusher('DATA', 'ru.prodamus.liza.data_message'),
        _pusher('MAC', 'com.prodamus.laba.liza', device: 'MacBook'),
      ]) {
        expect(
          _issues(_eval(pushers: [_pusher(_key, 'ru.prodamus.liza'), other])),
          isNot(contains(CheckupIssue.secondCopy)),
          reason: other.appId,
        );
      }
    });

    test('AC:RL-push-notification-checkup/3 account muted: master or '
        'silencing default rule; harmless deviations are ignored', () {
      const muted = CheckupFinding(
        CheckupIssue.accountMuted,
        CheckupAction.enableRules,
      );
      expect(_eval(rules: _rules(master: true)), contains(muted));
      expect(_eval(rules: _rules(message: false)), contains(muted));
      expect(
        _eval(rules: _rules(suppressEdits: false)),
        isNot(contains(muted)),
      );
      expect(_eval(rules: _rules()), isNot(contains(muted)));
    });

    test('AC:RL-push-notification-checkup/4 «Включить» flips only master and '
        'silencing defaults, never room mutes', () async {
      final calls = <String>[];
      Future<void> set(PushRuleKind kind, String id, bool enabled) async =>
          calls.add('${kind.name}/$id=$enabled');

      await enableAccountNotifications(
        _rules(master: true, message: false, suppressEdits: false),
        set,
      );
      expect(calls, [
        'override/.m.rule.master=false',
        'underride/.m.rule.message=true',
      ]);

      calls.clear();
      await enableAccountNotifications(_rules(), set);
      await enableAccountNotifications(null, set);
      expect(calls, isEmpty);
    });

    test('AC:RL-push-notification-checkup/5 outdated build, battery only on '
        'Android, Mac sleep fact only on macOS', () {
      expect(
        _eval(needsUpdate: true),
        contains(
          const CheckupFinding(
            CheckupIssue.outdatedBuild,
            CheckupAction.update,
          ),
        ),
      );
      expect(_issues(_eval()), isNot(contains(CheckupIssue.outdatedBuild)));
      const battery = {
        'liza.auth': 'authorized',
        'liza.battery_optimization': 'optimized',
      };
      expect(
        _issues(_eval(platform: 'android', tags: battery)),
        contains(CheckupIssue.batteryOptimized),
      );
      for (final platform in ['ios', 'macos']) {
        expect(
          _issues(_eval(platform: platform, tags: battery)),
          isNot(contains(CheckupIssue.batteryOptimized)),
        );
      }
      expect(
        _issues(
          _eval(
            platform: 'android',
            tags: {
              'liza.auth': 'authorized',
              'liza.battery_optimization': 'exempt',
            },
          ),
        ),
        isNot(contains(CheckupIssue.batteryOptimized)),
      );
      expect(_issues(_eval(platform: 'macos')), {CheckupIssue.macSleep});
      for (final platform in ['ios', 'android']) {
        expect(_issues(_eval(platform: platform)), isEmpty, reason: platform);
      }
    });
  });

  group('TestPushProbe', () {
    TestPushProbe probe(
      http.Client client, {
      required Future<Set<String>> Function() received,
    }) => TestPushProbe(
      endpoint: 'https://acks.example/test-push',
      pushkey: _key,
      appId: 'ru.prodamus.liza',
      openIdToken: 'openid-token',
      matrixServerName: 'example.com',
      httpClient: client,
      receivedHashes: received,
      timeout: const Duration(milliseconds: 60),
      pollInterval: const Duration(milliseconds: 5),
      nonce: () => 'abc',
    );

    test('AC:RL-push-notification-checkup/6 delivered by Ф1.1 hash, timed '
        'out, rejected; synthetic event only', () async {
      Map<String, Object?>? sent;
      final ok = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, Object?>;
        return http.Response('{}', 200);
      });
      final hash = pushAckHash(TestPushProbe.eventIdFor('abc'));
      expect(hash, hasLength(32));

      var polls = 0;
      final delivered = await probe(
        ok,
        received: () async => ++polls < 3 ? <String>{} : {hash},
      ).run();
      expect(delivered.status, TestPushStatus.delivered);
      expect(delivered.elapsed, isNotNull);
      expect(sent?['event_id'], r'$liza-test-abc');
      expect(sent?['pushkey'], _key);
      expect(sent?['app_id'], 'ru.prodamus.liza');
      expect((sent?['openid'] as Map)['matrix_server_name'], 'example.com');

      final other = await probe(
        ok,
        received: () async => {pushAckHash(r'$real-event')},
      ).run();
      expect(other.status, TestPushStatus.timedOut);

      for (final code in [400, 403, 500]) {
        var looked = false;
        final rejected = await probe(
          MockClient((_) async => http.Response('no', code)),
          received: () async {
            looked = true;
            return {hash};
          },
        ).run();
        expect(rejected.status, TestPushStatus.rejected, reason: '$code');
        expect(looked, isFalse, reason: 'rejected must not poll ($code)');
      }
    });
  });

  group('NotificationCheckupSection', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUpAll(() async {
      await L10n.delegate.load(const Locale('en'));
      await L10n.delegate.load(const Locale('ru'));
    });
    late Client client;
    late _MatrixState matrix;
    late NotificationHealth health;
    var auth = 1;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      client = await prepareTestClient(loggedIn: true);
      client.backgroundSync = false;
      await client.abortSync();
      matrix = _MatrixState(client);
      auth = 1;
      health = NotificationHealth(
        platform: 'ios',
        readSettings: () async => {'authorization': auth},
        openSettings: () async => true,
      );
    });

    tearDown(() async {
      health.dispose();
      await client.dispose(closeDatabase: true);
    });

    Future<BuildContext> pump(
      WidgetTester tester,
      String locale,
      List<Pusher>? pushers, {
      PushProbeStatus probe = PushProbeStatus.off,
    }) async {
      await tester.pumpWidget(const SizedBox());
      await health.refresh();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: Locale(locale),
          home: Provider<liza.MatrixState>.value(
            value: matrix,
            child: Scaffold(
              body: NotificationCheckupSection(
                health: health,
                platform: 'ios',
                loadPushers: (_) async => pushers,
                loadProbeStatus: (_) async => probe,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.element(find.byType(NotificationCheckupSection));
    }

    for (final locale in ['en', 'ru']) {
      testWidgets(
        'AC:RL-push-notification-checkup/7 $locale: real section shows '
        'reason rows with one fix button, all-clear otherwise',
        (tester) async {
          final context = await pump(tester, locale, [
            _pusher('OTHER', 'ru.prodamus.liza'),
          ]);
          final l10n = L10n.of(context);
          expect(find.text(l10n.notificationCheckupTitle), findsOneWidget);
          expect(
            find.text(l10n.notificationCheckupPermissionDenied),
            findsOneWidget,
          );
          expect(
            find.text(l10n.notificationCheckupPusherMissing),
            findsOneWidget,
          );
          expect(
            find.byKey(
              const ValueKey('notification-checkup-action-permissionDenied'),
            ),
            findsOneWidget,
          );
          expect(
            find.widgetWithText(TextButton, l10n.notificationCheckupReconnect),
            findsOneWidget,
          );
          expect(find.text(l10n.notificationCheckupAllClear), findsNothing);
          // Без адреса отправителя кнопки тестового пуша нет.
          expect(
            find.byKey(const ValueKey('notification-test-push')),
            findsNothing,
          );

          auth = 2;
          await pump(tester, locale, [_pusher(_key, 'ru.prodamus.liza')]);
          expect(find.text(l10n.notificationCheckupAllClear), findsOneWidget);
          expect(
            find.text(l10n.notificationCheckupPermissionDenied),
            findsNothing,
          );
          expect(
            find.text(l10n.notificationCheckupPusherMissing),
            findsNothing,
          );
        },
      );
    }

    testWidgets('AC:RL-push-test-sender-and-acks/10 кнопка тестового пуша — '
        'только когда сервер сказал test: true и свой pusher есть', (
      tester,
    ) async {
      auth = 2;
      final own = [_pusher(_key, 'ru.prodamus.liza')];
      await pump(tester, 'ru', own);
      expect(find.byKey(const ValueKey('notification-test-push')), findsNothing);
      await pump(
        tester,
        'ru',
        own,
        probe: const PushProbeStatus(test: true, acks: true),
      );
      expect(
        find.byKey(const ValueKey('notification-test-push')),
        findsOneWidget,
      );
      await pump(
        tester,
        'ru',
        [_pusher('OTHER', 'ru.prodamus.liza')],
        probe: const PushProbeStatus(test: true, acks: true),
      );
      expect(find.byKey(const ValueKey('notification-test-push')), findsNothing);
    });
  });
}
