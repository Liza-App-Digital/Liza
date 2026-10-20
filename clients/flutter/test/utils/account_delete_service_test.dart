// ledger:RL-account-delete-works
// AC:RL-account-delete-works/6 AC:RL-account-delete-works/7
//
// Самоудаление аккаунта через auth-proxy: ошибка эндпоинта не разлогинивает
// (AC-6), успешное удаление разлогинивает даже при размонтированном экране
// (AC-7). Логика вынесена из SettingsSecurityController в
// deleteAccountAndLogout — сам контроллер требует Matrix + GoRouter.
import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart' show Result;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:liza/utils/account_delete_service.dart';

AccountDeleteService _service(http.Client client) => AccountDeleteService(
      httpClient: client,
      baseUrl: 'auth.test',
      accessTokenProvider: () => 'tok',
      serverNameProvider: () => 'users.liza.ru',
    );

Future<Result<void>> _capture(Future<void> Function() action) =>
    Result.capture(action());

void main() {
  test('запрос: POST https://<auth-proxy>/api/account/delete, Bearer + server_name',
      () async {
    late http.Request seen;
    await _service(MockClient((req) async {
      seen = req;
      return http.Response('{"deleted": true}', 200);
    })).delete();
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'https://auth.test/api/account/delete');
    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(jsonDecode(seen.body), {'server_name': 'users.liza.ru'});
  });

  test('таймаут запроса — 60 с, не 10 с как у прочих вызовов auth-proxy', () {
    expect(AccountDeleteService.requestTimeout, const Duration(seconds: 60));
  });

  // AC:RL-account-delete-works/6
  group('AC-6: ошибка эндпоинта → исключение, логаута нет', () {
    final cases = <String, Future<http.Response> Function(http.Request)>{
      'сеть': (_) async => throw const SocketLikeException(),
      '5xx': (_) async => http.Response('{"error":"upstream_error"}', 502),
      '404 старого auth-proxy': (_) async => http.Response('Not Found', 404),
      '401': (_) async => http.Response('{"error":"unauthorized"}', 401),
      '409 служебный аккаунт': (_) async => http.Response(
            '{"error":"service_account","message":"x"}',
            409,
          ),
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        final service = _service(MockClient(entry.value));
        await expectLater(
          service.delete(),
          throwsA(
            isA<AccountDeleteException>().having(
              (e) => e.failure,
              'failure',
              AccountDeleteFailure.other,
            ),
          ),
        );
        var loggedOut = false;
        final deleted = await deleteAccountAndLogout(
          delete: service.delete,
          markExplicitLogout: () {},
          unmarkExplicitLogout: () {},
          logout: () async => loggedOut = true,
          runWithProgress: _capture,
          isMounted: () => true,
        );
        expect(deleted, isFalse);
        expect(loggedOut, isFalse, reason: 'аккаунт жив — сессию не рвём');
      });
    }

    test('409 company_owner → отдельная причина «передайте владение»', () async {
      // Тело — как у auth-proxy: UTF-8 с кириллицей (ensure_ascii=False).
      final service = _service(MockClient((_) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'error': 'company_owner',
              'message': 'Сначала передайте владение компанией',
            })),
            409,
            headers: {'content-type': 'application/json; charset=utf-8'},
          )));
      await expectLater(
        service.delete(),
        throwsA(
          isA<AccountDeleteException>().having(
            (e) => e.failure,
            'failure',
            AccountDeleteFailure.companyOwner,
          ),
        ),
      );
    });

    test('таймаут: на 59 с ещё ждём, после 60 с — исключение', () {
      fakeAsync((async) {
        Object? error;
        _service(
          MockClient((_) => Completer<http.Response>().future),
        ).delete().catchError((Object e) => error = e);
        async.elapse(const Duration(seconds: 59));
        expect(error, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(error, isA<AccountDeleteException>());
      });
    });
  });

  // AC:RL-account-delete-works/7
  group('пометка явного выхода при отказе', () {
    Future<List<String>> run(Object error) async {
      final calls = <String>[];
      await deleteAccountAndLogout(
        delete: () async => throw error,
        markExplicitLogout: () => calls.add('mark'),
        unmarkExplicitLogout: () => calls.add('unmark'),
        logout: () async => calls.add('logout'),
        runWithProgress: _capture,
        isMounted: () => true,
      );
      return calls;
    }

    test('сервер отказал (409 владелец компании) → пометка снята', () async {
      expect(
        await run(const AccountDeleteException(
          AccountDeleteFailure.companyOwner,
          statusCode: 409,
        )),
        ['mark', 'unmark'],
      );
    });

    test('обрыв без ответа → пометка держится: сервер мог успеть удалить',
        () async {
      expect(
        await run(const AccountDeleteException(AccountDeleteFailure.other)),
        ['mark'],
      );
    });
  });

  group('AC-7: успех → logout всегда', () {
    test('экран размонтирован после delete → logout без диалога', () async {
      final calls = <String>[];
      final deleted = await deleteAccountAndLogout(
        delete: () async => calls.add('delete'),
        markExplicitLogout: () => calls.add('mark'),
        unmarkExplicitLogout: () => calls.add('unmark'),
        logout: () async => calls.add('logout'),
        runWithProgress: (action) {
          calls.add('dialog');
          return _capture(action);
        },
        isMounted: () => false,
      );
      expect(deleted, isTrue);
      expect(calls, ['mark', 'dialog', 'delete', 'logout']);
    });

    test('экран на месте → logout под диалогом прогресса', () async {
      final calls = <String>[];
      await deleteAccountAndLogout(
        delete: () async => calls.add('delete'),
        markExplicitLogout: () => calls.add('mark'),
        unmarkExplicitLogout: () => calls.add('unmark'),
        logout: () async => calls.add('logout'),
        runWithProgress: (action) {
          calls.add('dialog');
          return _capture(action);
        },
        isMounted: () => true,
      );
      expect(calls, ['mark', 'dialog', 'delete', 'dialog', 'logout']);
    });
  });
}

class SocketLikeException implements Exception {
  const SocketLikeException();
}
