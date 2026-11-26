// Страж реестра регрессии: ledger:RL-db-quarantine-not-delete (см. tests/registry/).
//
// Нулевой уровень стоп-крана обновления matrix SDK: события хранилища и
// сессии уходят в мониторинг только с причиной из закрытого перечня, разлогин
// считается лишь на переходе loggedIn → loggedOut, нерасшифрованные — по
// состоянию события при получении.

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/db_file_guard.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/session_health_metrics.dart';

import 'test_client.dart';

void main() {
  group('заголовки событий [AC:RL-db-quarantine-not-delete/8]', () {
    test('все причины хранилища дают короткий заголовок без путей', () {
      for (final event in DbStorageEvent.values) {
        final title = Monitoring.dbStorageTitle(event.wire);
        expect(title, '[db-storage] reason=${event.wire}');
        expect(title!.length, lessThanOrEqualTo(Monitoring.maxAlertTitleLength));
      }
      for (final reason in LogoutReason.values) {
        expect(
          Monitoring.sessionLogoutTitle(reason.wire),
          '[session] logout reason=${reason.wire}',
        );
      }
    });

    test('свободный текст вместо причины не уходит', () {
      for (final bad in [
        '/Users/me/Library/liza.sqlite',
        '@alice:example.org',
        'file is not a database',
        '',
        'x' * 40,
      ]) {
        expect(Monitoring.dbStorageTitle(bad), isNull, reason: bad);
        expect(Monitoring.sessionLogoutTitle(bad), isNull, reason: bad);
      }
    });

    test('троттл: та же причина не чаще раза в 5 минут', () {
      Monitoring.resetStorageThrottle();
      final t = DateTime(2026, 11, 25, 10);
      expect(Monitoring.storageThrottleAllows('a', t), isTrue);
      expect(
        Monitoring.storageThrottleAllows('a', t.add(const Duration(minutes: 4))),
        isFalse,
      );
      expect(Monitoring.storageThrottleAllows('b', t), isTrue);
      expect(
        Monitoring.storageThrottleAllows('a', t.add(const Duration(minutes: 5))),
        isTrue,
      );
    });

    test('без поднятого мониторинга отчёт ничего не бросает', () {
      expect(Monitoring.isActive, isFalse);
      Monitoring.reportDbStorage('quarantine-open');
      Monitoring.reportSessionLogout('other');
    });
  });

  group('причина разлогина [AC:RL-db-quarantine-not-delete/9]', () {
    final cases = <String, (LoginState?, LoginState, bool, bool, LogoutReason?)>{
      'пользователь нажал «Выйти»': (
        LoginState.loggedIn, LoginState.loggedOut, true, false, LogoutReason.user,
      ),
      'сервер погасил токен': (
        LoginState.loggedIn,
        LoginState.loggedOut,
        false,
        true,
        LogoutReason.unknownToken,
      ),
      'явный выход важнее токена': (
        LoginState.loggedIn, LoginState.loggedOut, true, true, LogoutReason.user,
      ),
      'прочее': (
        LoginState.loggedIn, LoginState.loggedOut, false, false, LogoutReason.other,
      ),
      'холодный старт без сессии': (null, LoginState.loggedOut, false, false, null),
      'повторный loggedOut': (
        LoginState.loggedOut, LoginState.loggedOut, false, true, null,
      ),
      'вход': (LoginState.loggedOut, LoginState.loggedIn, false, false, null),
      'soft logout': (
        LoginState.loggedIn, LoginState.softLoggedOut, false, true, null,
      ),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        final (previous, next, explicit, unknownToken, expected) = entry.value;
        expect(
          classifyLogout(
            previous: previous,
            next: next,
            explicit: explicit,
            unknownTokenSeen: unknownToken,
          ),
          expected,
        );
      });
    }
  });

  group('нерасшифрованные при получении [AC:RL-db-quarantine-not-delete/10]', () {
    late Room room;

    setUpAll(() async {
      room = Room(id: '!r:x', client: await prepareTestClient());
    });

    Event event(String type, {MatrixEvent? originalSource}) => Event(
      type: type,
      content: const {},
      eventId: '\$e',
      senderId: '@a:x',
      originServerTs: DateTime(2026),
      room: room,
      originalSource: originalSource,
    );

    test('осталось зашифрованным → undecryptable', () {
      expect(
        classifyArrival(event(EventTypes.Encrypted)),
        E2eeArrival.undecryptable,
      );
    });

    test('расшифровано SDK → decrypted', () {
      final encrypted = MatrixEvent(
        type: EventTypes.Encrypted,
        content: const {},
        eventId: '\$e',
        senderId: '@a:x',
        originServerTs: DateTime(2026),
      );
      expect(
        classifyArrival(event(EventTypes.Message, originalSource: encrypted)),
        E2eeArrival.decrypted,
      );
    });

    test('незашифрованная комната → plain', () {
      expect(classifyArrival(event(EventTypes.Message)), E2eeArrival.plain);
    });

    test('take отдаёт накопленное и обнуляет', () async {
      SharedPreferences.setMockInitialValues({
        SessionHealthMetrics.receivedKey: 12,
        SessionHealthMetrics.utdKey: 3,
      });
      final prefs = await SharedPreferences.getInstance();

      expect(await SessionHealthMetrics.take(prefs), (received: 12, utd: 3));
      expect(await SessionHealthMetrics.take(prefs), (received: 0, utd: 0));
    });
  });
}
