// Настоящие localhost HTTP-соединения, инъекция только AES-примитива.
// ledger:RL-e2ee-video-proxy-resume
// ledger:RL-video-stream-progress-and-lifecycle
// guard.render: unit
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liza/utils/e2ee_media_proxy.dart';
import 'package:liza/utils/foreground_witness.dart';

import 'test_client.dart';

// ForegroundWitness production-регистрации нужен binding, но HTTP здесь
// настоящий localhost: стандартный HTTP400 override намеренно не включаем.
class _ProxyTransportBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  final binding = _ProxyTransportBinding();
  final proxy = E2eeMediaProxy.instance;
  final savedCtr = E2eeMediaProxy.aesCtrImpl;
  var decryptedBytes = 0;
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    decryptedBytes = 0;
    E2eeMediaProxy.aesCtrImpl = ({required input, required key, required iv}) {
      decryptedBytes += input.length;
      return input;
    };
    await proxy.ensureStarted();
  });
  tearDown(() async {
    await proxy.stop();
    E2eeMediaProxy.aesCtrImpl = savedCtr;
  });

  Future<HttpServer> upstream(Future<void> Function(HttpRequest) serve) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      try {
        req.response.bufferOutput = false;
        await serve(req);
      } on SocketException {
        // Отмена downstream/lease намеренно закрывает транспорт.
      } on HttpException {
        // То же после отправки Content-Length и неполного тела.
      }
    });
    addTearDown(() => server.close(force: true));
    return server;
  }

  String register(
    HttpServer server, {
    int size = 64,
    String mimetype = 'video/mp4',
    String? token,
    ForegroundWitness? witness,
    Duration headers = const Duration(seconds: 2),
    Duration idle = const Duration(seconds: 2),
    Duration progress = const Duration(seconds: 4),
    Duration backoff = const Duration(milliseconds: 5),
  }) => proxy.registerRawSessionForTest(
    downloadUri: Uri.parse('http://127.0.0.1:${server.port}/same-media'),
    keyBytes: Uint8List(32),
    ivBytes: Uint8List(16),
    fileSize: size,
    accessToken: token,
    mimetype: mimetype,
    witness: witness,
    headersTimeout: headers,
    bodyIdleTimeout: idle,
    progressTimeout: progress,
    backoffBase: backoff,
  );

  String sid(String url) => Uri.parse(url).pathSegments.single;

  Future<List<int>> read(
    String url, {
    HttpClient? using,
    void Function(List<int>)? onChunk,
  }) async {
    final client = using ?? HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      final result = <int>[];
      await for (final chunk in response) {
        result.addAll(chunk);
        onChunk?.call(chunk);
      }
      return result;
    } finally {
      if (using == null) client.close(force: true);
    }
  }

  Future<void> until(bool Function() condition) async {
    final stopwatch = Stopwatch()..start();
    while (!condition()) {
      if (stopwatch.elapsed > const Duration(seconds: 3)) {
        fail('Ожидаемое состояние не наступило за 3с');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void rangeHeaders(
    HttpResponse response,
    int start,
    int end,
    int total, {
    bool chunked = false,
  }) {
    response.statusCode = 206;
    response.headers.set('content-range', 'bytes $start-$end/$total');
    if (!chunked) response.contentLength = end - start + 1;
  }

  // AC:RL-e2ee-video-proxy-resume/8
  // AC:RL-video-stream-progress-and-lifecycle/13
  for (final error in [
    '401',
    '404',
    '500',
    'wrong-start',
    'wrong-total',
    'wrong-length',
    'missing-range',
  ]) {
    test(
      'HTTP $error: ошибочное тело не попадает в decrypt/progress',
      () async {
        final server = await upstream((req) async {
          final code = int.tryParse(error);
          req.response.statusCode = code ?? 206;
          req.response.contentLength = 64;
          if (code == null && error != 'missing-range') {
            req.response.headers.set('content-range', switch (error) {
              'wrong-start' => 'bytes 16-79/80',
              'wrong-total' => 'bytes 0-63/80',
              _ => 'bytes 0-31/64',
            });
          }
          req.response.add(List.filled(64, 65));
          await req.response.close();
        });
        final url = register(server);
        await expectLater(read(url), throwsA(anything));
        expect(decryptedBytes, 0);
        expect(proxy.snapshot(sid(url))!.receivedBytes, 0);
        expect(proxy.snapshot(sid(url))!.phase, E2eeProxyPhase.failed);
      },
    );
  }

  // AC:RL-e2ee-video-proxy-resume/8
  // AC:RL-video-stream-progress-and-lifecycle/13
  test(
    '200 допустим только на offset 0 и с полной согласованной длиной',
    () async {
      final server = await upstream((req) async {
        req.response.contentLength = 64;
        req.response.add(List.generate(64, (i) => i));
        await req.response.close();
      });
      expect(await read(register(server)), List.generate(64, (i) => i));
      expect(decryptedBytes, 64);
    },
  );

  // AC:RL-e2ee-video-proxy-resume/8
  // AC:RL-video-stream-progress-and-lifecycle/13
  test(
    '200 на resume offset32: запрещён, ошибочные байты не добавляются',
    () async {
      var requests = 0;
      final server = await upstream((req) async {
        requests++;
        if (requests == 1) {
          final socket = await req.response.detachSocket(writeHeaders: false);
          socket.write(
            'HTTP/1.1 206 Partial Content\r\nContent-Length: 64\r\nContent-Range: bytes 0-63/64\r\n\r\n',
          );
          socket.add(List.filled(32, 65));
          await socket.flush();
          await socket.close();
        } else {
          expect(req.headers.value('range'), 'bytes=32-63');
          req.response.contentLength = 64;
          req.response.add(List.filled(64, 66));
          await req.response.close();
        }
      });
      final url = register(server);
      await expectLater(read(url), throwsA(anything));
      expect(requests, 2);
      expect(decryptedBytes, 32);
      expect(proxy.snapshot(sid(url))!.receivedBytes, 32);
      expect(proxy.snapshot(sid(url))!.failureReason, 'invalid-full-response');
    },
  );

  // AC:RL-e2ee-video-proxy-resume/8
  // AC:RL-video-stream-progress-and-lifecycle/13
  test(
    'чистый короткий chunked EOF → точная докачка, не ложный успех',
    () async {
      var requests = 0;
      final server = await upstream((req) async {
        final start = requests++ == 0 ? 0 : 32;
        rangeHeaders(req.response, start, 63, 64, chunked: true);
        req.response.add(List.generate(32, (i) => start + i));
        await req.response.close();
      });
      final url = register(server);
      expect(await read(url), List.generate(64, (i) => i));
      expect(requests, 2);
      expect(proxy.snapshot(sid(url))!.receivedBytes, 64);
    },
  );

  // AC:RL-e2ee-video-proxy-resume/6
  // AC:RL-video-stream-progress-and-lifecycle/11
  for (final phase in ['headers', 'body', 'backoff']) {
    test(
      'cancel A в $phase: уже читающая B того же Event продолжает byte-exact',
      () async {
        final firstRequestA = Completer<void>();
        final releaseA = Completer<void>();
        final releaseB = Completer<void>();
        final payload = List.generate(64, (i) => (i * 37 + 11) & 0xff);
        final upstreamRequests = <Uri>[];
        final server = await upstream((req) async {
          upstreamRequests.add(req.uri);
          final requestNumber = upstreamRequests.length;
          // A начинает первой и удерживается барьером до появления prefix B.
          // Поэтому только второй HTTP-запрос принадлежит B; третий и далее
          // означали бы запрещённый retry A либо оборванную B.
          if (requestNumber == 2) {
            rangeHeaders(req.response, 0, 63, 64);
            req.response.add(payload.sublist(0, 32));
            await req.response.flush();
            await releaseB.future;
            req.response.add(payload.sublist(32));
            await req.response.close();
            return;
          }
          if (requestNumber == 1) firstRequestA.complete();
          if (phase == 'body') {
            rangeHeaders(req.response, 0, 63, 64);
            req.response.add(payload.sublist(0, 32));
            await req.response.flush();
          }
          await releaseA.future;
          if (phase == 'backoff') {
            final socket = await req.response.detachSocket(writeHeaders: false);
            socket.write(
              'HTTP/1.1 206 Partial Content\r\nContent-Length: 64\r\nContent-Range: bytes 0-63/64\r\n\r\n',
            );
            await socket.flush();
            await socket.close();
          } else {
            await req.response.close();
          }
        });
        final client = await prepareTestClient(
          loggedIn: true,
          homeserver: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        addTearDown(() => client.dispose(closeDatabase: true));
        addTearDown(() {
          if (!releaseA.isCompleted) releaseA.complete();
          if (!releaseB.isCompleted) releaseB.complete();
        });
        final event = Event(
          type: EventTypes.Message,
          eventId: r'$same-encrypted-video',
          senderId: '@alice:example.invalid',
          originServerTs: DateTime(2026, 10, 30),
          room: Room(id: '!room:example.invalid', client: client),
          content: {
            'msgtype': 'm.video',
            'body': 'fixture.mp4',
            'file': {
              'url': 'mxc://example.invalid/same-media',
              'key': {
                'k': base64Url.encode(Uint8List(32)),
                'alg': 'A256CTR',
                'kty': 'oct',
              },
              'iv': base64.encode(Uint8List(16)),
              'hashes': {'sha256': 'fixture-hash'},
              'v': 'v2',
            },
            'info': {'size': payload.length, 'mimetype': 'video/mp4'},
          },
        );
        // Оба lease создаёт production API из ТОГО ЖЕ объекта Event.
        final a = await proxy.registerSession(event: event);
        final b = await proxy.registerSession(event: event);
        expect(a, isNot(b));
        final aResult = expectLater(read(a), throwsA(anything));
        await firstRequestA.future.timeout(const Duration(seconds: 3));

        final prefixB = <int>[];
        var bCompleted = false;
        final bResult = read(b, onChunk: prefixB.addAll).then((bytes) {
          bCompleted = true;
          return bytes;
        });
        final bAssertion = expectLater(bResult, completion(equals(payload)));
        await until(() => prefixB.length == 32);
        expect(prefixB, payload.sublist(0, 32));
        expect(upstreamRequests, hasLength(2));
        expect(
          upstreamRequests[0],
          upstreamRequests[1],
          reason: 'оба lease читают один и тот же media endpoint',
        );

        if (phase == 'backoff') releaseA.complete();
        final expectedPhaseA = switch (phase) {
          'headers' => E2eeProxyPhase.connecting,
          'body' => E2eeProxyPhase.streaming,
          _ => E2eeProxyPhase.retrying,
        };
        await until(() => proxy.snapshot(sid(a))?.phase == expectedPhaseA);
        final activeA = proxy.snapshot(sid(a))!;
        final activeB = proxy.snapshot(sid(b))!;
        expect(activeA.activeRequests, 1);
        if (phase == 'body') expect(activeA.receivedBytes, 32);
        expect(activeB.activeRequests, 1);
        expect(activeB.phase, E2eeProxyPhase.streaming);
        expect(activeB.receivedBytes, 32);
        expect(
          bCompleted,
          isFalse,
          reason: 'B уже приняла prefix, но ещё не закончила до отмены A',
        );

        await proxy.cancelSession(sid(a)).timeout(const Duration(seconds: 1));
        await aResult;
        expect(proxy.snapshot(sid(a)), isNull);
        expect(proxy.snapshot(sid(b))!.activeRequests, 1);
        expect(
          bCompleted,
          isFalse,
          reason: 'отмена A не закрыла активное соединение B',
        );
        // Срок больше production backoff200мс первого retry. B всё ещё держит
        // своё соединение: нельзя заменить доказательство новым read(B).
        await Future<void>.delayed(const Duration(milliseconds: 260));
        expect(
          upstreamRequests,
          hasLength(2),
          reason: 'A не возрождается и B не вынуждена переподключаться',
        );
        releaseB.complete();
        await bAssertion;
        expect(await bResult, payload);
        expect(proxy.snapshot(sid(b))!.receivedBytes, payload.length);
        expect(upstreamRequests, hasLength(2));
        if (!releaseA.isCompleted) releaseA.complete();
      },
    );
  }

  // AC:RL-e2ee-video-proxy-resume/9
  // AC:RL-video-stream-progress-and-lifecycle/3
  // AC:RL-video-stream-progress-and-lifecycle/14
  for (final phase in ['headers', 'body']) {
    test(
      '$phase idle ограничен, общий recovery deadline ограничивает все retries',
      () async {
        var requests = 0;
        final gates = <Completer<void>>[];
        final server = await upstream((req) async {
          requests++;
          if (phase == 'body') {
            rangeHeaders(req.response, 0, 63, 64);
            await req.response.flush();
          }
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          await req.response.close();
        });
        final url = register(
          server,
          headers: const Duration(milliseconds: 120),
          idle: const Duration(milliseconds: 120),
          progress: const Duration(milliseconds: 350),
        );
        final clock = Stopwatch()..start();
        await expectLater(read(url), throwsA(anything));
        expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
        expect(
          requests,
          greaterThan(1),
          reason:
              'первый запрос действительно истёк отдельно от общего бюджета',
        );
        expect(proxy.snapshot(sid(url))!.failureReason, 'progress-timeout');
        for (final gate in gates) {
          gate.complete();
        }
      },
    );
  }

  // AC:RL-e2ee-video-proxy-resume/10
  // AC:RL-video-stream-progress-and-lifecycle/1
  // AC:RL-video-stream-progress-and-lifecycle/14
  test(
    'живые чанки перевзводят idle/progress, длительность файла не ограничена',
    () async {
      final server = await upstream((req) async {
        rangeHeaders(req.response, 0, 255, 256);
        for (var i = 0; i < 16; i++) {
          req.response.add(List.generate(16, (j) => i * 16 + j));
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        await req.response.close();
      });
      final url = register(
        server,
        size: 256,
        idle: const Duration(milliseconds: 150),
        progress: const Duration(milliseconds: 200),
      );
      expect(await read(url), List.generate(256, (i) => i));
      expect(proxy.snapshot(sid(url))!.receivedBytes, 256);
      expect(proxy.snapshot(sid(url))!.phase, E2eeProxyPhase.completed);
    },
  );

  // AC:RL-e2ee-video-proxy-resume/11
  // AC:RL-video-stream-progress-and-lifecycle/5
  test(
    'сон дольше бюджета не терминалит и не стартует retries; resume даёт свежий срок',
    () async {
      final witness = ForegroundWitness.manual(
        initial: AppLifecycleState.resumed,
        resumeGrace: const Duration(milliseconds: 50),
      );
      addTearDown(witness.dispose);
      final first = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      final server = await upstream((req) async {
        requests++;
        rangeHeaders(req.response, 0, 63, 64);
        req.response.add(List.filled(32, 65));
        await req.response.flush();
        first.complete();
        await release.future;
        req.response.add(List.filled(32, 66));
        await req.response.close();
      });
      final url = register(
        server,
        witness: witness,
        idle: const Duration(milliseconds: 120),
        progress: const Duration(milliseconds: 200),
      );
      final result = read(url);
      await first.future;
      witness.onStateChange(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(requests, 1);
      expect(proxy.snapshot(sid(url))!.phase, E2eeProxyPhase.streaming);
      witness.onStateChange(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      release.complete();
      expect(await result, [...List.filled(32, 65), ...List.filled(32, 66)]);
    },
  );
  // AC:RL-e2ee-video-proxy-resume/6
  // AC:RL-video-stream-progress-and-lifecycle/11
  test(
    'downstream close во время idle body отменяет request, но не lease',
    () async {
      var requests = 0;
      final release = Completer<void>();
      final server = await upstream((req) async {
        requests++;
        rangeHeaders(req.response, 0, 63, 64);
        if (requests == 1) {
          req.response.add(List.filled(16, 65));
          await req.response.flush();
          await release.future;
        } else {
          req.response.add(List.generate(64, (i) => i));
        }
        await req.response.close();
      });
      final url = register(server);
      final client = HttpClient();
      final response = await (await client.getUrl(Uri.parse(url))).close();
      final first = await response.first;
      expect(first, List.filled(16, 65));
      client.close(force: true);
      await until(() => proxy.snapshot(sid(url))!.activeRequests == 0);
      expect(proxy.snapshot(sid(url))!.phase, isNot(E2eeProxyPhase.failed));
      expect(await read(url), List.generate(64, (i) => i));
      release.complete();
    },
  );
  // AC:RL-e2ee-video-proxy-resume/8
  // AC:RL-video-stream-progress-and-lifecycle/13
  for (final changedTotal in [false, true]) {
    test(
      'нет info.size: partial206 докачивается, changedTotal=$changedTotal',
      () async {
        var requests = 0;
        final server = await upstream((req) async {
          final start = requests++ == 0 ? 0 : 32;
          final total = changedTotal && start > 0 ? 128 : 64;
          rangeHeaders(req.response, start, start + 31, total);
          req.response.add(List.generate(32, (i) => start + i));
          await req.response.close();
        });
        final url = register(server, size: 0);
        if (changedTotal) {
          await expectLater(read(url), throwsA(anything));
          expect(proxy.snapshot(sid(url))!.receivedBytes, 32);
          expect(
            proxy.snapshot(sid(url))!.failureReason,
            'invalid-content-range',
          );
        } else {
          expect(await read(url), List.generate(64, (i) => i));
          expect(proxy.snapshot(sid(url))!.receivedBytes, 64);
        }
        expect(requests, 2);
      },
    );
  }
  // AC:RL-e2ee-video-proxy-resume/13
  test('MIME из Event с CRLF не инжектируется в raw HTTP', () async {
    var requests = 0;
    final server = await upstream((req) async {
      requests++;
      rangeHeaders(req.response, 0, 63, 64);
      req.response.add(List.filled(64, 65));
      await req.response.close();
    });
    final url = register(
      server,
      mimetype: 'video/mp4; x="ok\r\nX-Injected: yes\r\n\r\nBODY"',
    );
    await expectLater(read(url), throwsA(anything));
    expect(requests, 0);
    expect(decryptedBytes, 0);
    expect(proxy.snapshot(sid(url))!.failureReason, 'invalid-content-type');
  });
  // AC:RL-e2ee-video-proxy-resume/12
  test(
    'заполненный downstream приостанавливает upstream и deadlines',
    () async {
      const size = 32 * 1024 * 1024;
      final server = await upstream((req) async {
        rangeHeaders(req.response, 0, size - 1, size);
        final chunk = Uint8List(64 * 1024);
        for (var sent = 0; sent < size; sent += chunk.length) {
          req.response.add(chunk);
          await req.response.flush();
        }
        await req.response.close();
      });
      final url = register(
        server,
        size: size,
        idle: const Duration(milliseconds: 200),
        progress: const Duration(milliseconds: 300),
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(Uri.parse(url))).close();
      final first = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      subscription = response.listen((_) {
        if (!first.isCompleted) {
          subscription.pause();
          first.complete();
        }
      });
      await first.future;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final state = proxy.snapshot(sid(url))!;
      expect(
        state.receivedBytes,
        lessThan(size),
        reason:
            'прокси не вычитывает файл целиком при остановленном потребителе',
      );
      expect(state.phase, isNot(E2eeProxyPhase.failed));
      await proxy.cancelSession(sid(url)).timeout(const Duration(seconds: 1));
      await subscription.cancel();
    },
  );
}
