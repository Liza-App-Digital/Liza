// ledger:RL-seen-by-strip-avatar-resolution
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/utils/reader_profile_resolver.dart';

import 'test_client.dart';

String _id(String n) => '@$n:example.invalid';

class _Api extends FakeMatrixApi {
  final status = <String, int>{};
  final calls = <String, int>{};
  final gates = <Completer<void>>[];
  var hold = false;
  var inFlight = 0;
  var maxInFlight = 0;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final seg = request.url.pathSegments;
    if (!seg.contains('profile')) return super.mockIntercept(request);
    final id = Uri.decodeComponent(seg.last);
    calls.update(id, (n) => n + 1, ifAbsent: () => 1);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (hold) {
        final g = Completer<void>();
        gates.add(g);
        await g.future;
      }
      final code = status[id] ?? 200;
      if (code != 200) {
        return http.Response(
          jsonEncode({
            'errcode': code == 404
                ? 'M_NOT_FOUND'
                : code == 403
                ? 'M_FORBIDDEN'
                : 'M_UNKNOWN',
          }),
          code,
        );
      }
      return http.Response(
        jsonEncode({
          'displayname': 'N',
          'avatar_url':
              'mxc://example.invalid/${id.substring(1, id.indexOf(':'))}',
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    } finally {
      inFlight--;
    }
  }
}

void main() {
  late Client client;
  late _Api api;
  late List<ReaderProfileOutcome> outcomes;
  var now = DateTime(2026, 11, 23);
  late ReaderProfileResolver resolver;

  Future<void> setUpResolver(WidgetTester t, {int maxEntries = 500}) async {
    await t.runAsync(() async {
      api = _Api();
      client = await prepareTestClient(loggedIn: true, httpClient: api);
    });
    outcomes = [];
    now = DateTime(2026, 11, 23);
    resolver = ReaderProfileResolver(
      client,
      maxEntries: maxEntries,
      onOutcome: outcomes.add,
      now: () => now,
    );
    addTearDown(resolver.dispose);
  }

  // Запросы идут в реальном async, колбэки — в fake-зоне: чередуем и то и другое.
  Future<void> wait(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('успех: профиль в ValueListenable, повторный ensure без сети', (
    t,
  ) async {
    await setUpResolver(t);
    resolver.ensure(_id('anna'));
    await wait(t);
    expect(
      resolver.watch(_id('anna')).value?.avatarUrl,
      Uri.parse('mxc://example.invalid/anna'),
    );
    resolver.ensure(_id('anna'));
    await wait(t);
    expect(api.calls[_id('anna')], 1);
    expect(outcomes, [ReaderProfileOutcome.resolved]);
  });

  testWidgets('404: отрицательный кэш 10 мин, потом повтор', (t) async {
    await setUpResolver(t);
    api.status[_id('ghost')] = 404;
    resolver.ensure(_id('ghost'));
    await wait(t);
    for (var i = 0; i < 5; i++) {
      resolver.ensure(_id('ghost'));
    }
    await wait(t);
    expect(api.calls[_id('ghost')], 1);
    now = now.add(const Duration(minutes: 11));
    resolver.ensure(_id('ghost'));
    await wait(t);
    expect(api.calls[_id('ghost')], 2);
    expect(outcomes.every((o) => o == ReaderProfileOutcome.notFound), isTrue);
  });

  testWidgets('403 → forbidden и отрицательный кэш', (t) async {
    await setUpResolver(t);
    api.status[_id('closed')] = 403;
    resolver.ensure(_id('closed'));
    await wait(t);
    resolver.ensure(_id('closed'));
    await wait(t);
    expect(api.calls[_id('closed')], 1);
    expect(outcomes, [ReaderProfileOutcome.forbidden]);
  });

  testWidgets('невалидный MXID — без сети, исход invalid', (t) async {
    await setUpResolver(t);
    for (final bad in [
      '',
      'anna',
      '@:example.invalid',
      '#room:example.invalid',
    ]) {
      resolver.ensure(bad);
    }
    await wait(t);
    expect(api.calls, isEmpty);
    expect(outcomes.where((o) => o == ReaderProfileOutcome.invalid).length, 4);
  });

  testWidgets('5xx: backoff 30 с, затем повтор; исход error', (t) async {
    await setUpResolver(t);
    api.status[_id('flaky')] = 500;
    resolver.ensure(_id('flaky'));
    await wait(t);
    resolver.ensure(_id('flaky'));
    await wait(t);
    expect(api.calls[_id('flaky')], 1);
    now = now.add(const Duration(seconds: 31));
    resolver.ensure(_id('flaky'));
    await wait(t);
    expect(api.calls[_id('flaky')], 2);
    expect(outcomes, [ReaderProfileOutcome.error, ReaderProfileOutcome.error]);
  });

  testWidgets('дедуп in-flight и потолок параллелизма 3', (t) async {
    await setUpResolver(t);
    api.hold = true;
    for (var i = 0; i < 8; i++) {
      resolver.ensure(_id('u$i'));
      resolver.ensure(_id('u$i'));
    }
    await wait(t);
    expect(api.maxInFlight, lessThanOrEqualTo(3));
    expect(api.calls.values.every((n) => n == 1), isTrue);
    api.hold = false;
    for (var i = 0; i < 20 && api.calls.length < 8; i++) {
      for (final g in api.gates.where((g) => !g.isCompleted).toList()) {
        g.complete();
      }
      await wait(t);
    }
    for (final g in api.gates.where((g) => !g.isCompleted)) {
      g.complete();
    }
    await wait(t);
    expect(api.calls.length, 8);
    expect(api.maxInFlight, lessThanOrEqualTo(3));
  });

  testWidgets('LRU: сверх maxEntries самая старая запись вытесняется', (
    t,
  ) async {
    await setUpResolver(t, maxEntries: 2);
    final first = resolver.watch(_id('a'));
    resolver.watch(_id('b'));
    resolver.watch(_id('c'));
    expect(identical(resolver.watch(_id('a')), first), isFalse);
  });

  testWidgets('два клиента — независимые резолверы', (t) async {
    await setUpResolver(t);
    late Client other;
    await t.runAsync(() async {
      other = await prepareTestClient(loggedIn: true, httpClient: _Api());
    });
    expect(
      identical(
        ReaderProfileResolver.of(client),
        ReaderProfileResolver.of(other),
      ),
      isFalse,
    );
    expect(
      identical(
        ReaderProfileResolver.of(client),
        ReaderProfileResolver.of(client),
      ),
      isTrue,
    );
  });

  testWidgets('fetch: один запрос на ensure+fetch, результат из общего кэша', (
    t,
  ) async {
    await setUpResolver(t);
    resolver.ensure(_id('fia'));
    ReaderProfile? got;
    unawaited(resolver.fetch(_id('fia')).then((p) => got = p));
    await wait(t);
    expect(api.calls[_id('fia')], 1);
    expect(got?.avatarUrl, Uri.parse('mxc://example.invalid/fia'));
    // 404 → fetch отдаёт null и не повторяет запрос в окне отрицательного кэша.
    api.status[_id('nope')] = 404;
    ReaderProfile? miss = const ReaderProfile();
    unawaited(resolver.fetch(_id('nope')).then((p) => miss = p));
    await wait(t);
    unawaited(resolver.fetch(_id('nope')).then((p) => miss = p));
    await wait(t);
    expect(miss, isNull);
    expect(api.calls[_id('nope')], 1);
  });

  testWidgets('сверка после сбоя миниатюры: один раз на пару (userId, URL)', (
    t,
  ) async {
    await setUpResolver(t);
    final old = Uri.parse('mxc://example.invalid/old');
    resolver.watch(_id('pat'));
    unawaited(resolver.recheckAfterThumbFailure(_id('pat'), old));
    unawaited(resolver.recheckAfterThumbFailure(_id('pat'), old));
    await wait(t);
    expect(api.calls[_id('pat')], 1);
    expect(
      resolver.watch(_id('pat')).value?.avatarUrl,
      Uri.parse('mxc://example.invalid/pat'),
    );
    // Другой URL — новая пара, новая сверка.
    unawaited(
      resolver.recheckAfterThumbFailure(
        _id('pat'),
        Uri.parse('mxc://example.invalid/older'),
      ),
    );
    await wait(t);
    expect(api.calls[_id('pat')], 2);
  });

  test('ReaderProfile: равные поля равны (не будят слушателей)', () {
    final a = ReaderProfile(
      displayName: 'N',
      avatarUrl: Uri.parse('mxc://a/b'),
    );
    final b = ReaderProfile(
      displayName: 'N',
      avatarUrl: Uri.parse('mxc://a/b'),
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
