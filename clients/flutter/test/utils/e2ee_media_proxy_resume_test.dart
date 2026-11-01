// Страж resume-докачки E2EE-медиа-прокси (2026-08-31).
//
// Корень бага (лог Романа): при обрыве TCP на мобильном пути E2eeMediaProxy
// рестартил upstream-скачивание с байта 0 → 169МБ E2EE `Connection closed while
// receiving data` повторяясь минутами и никогда не докачивалось. Фикс —
// _resumableUpstream: на обрыв переоткрывает GET с `Range: bytes=<позиция>-` и
// продолжает, consumer (decryptCtrStream) видит непрерывный поток, counter верен.
//
// Тест — end-to-end через РЕАЛЬНЫЙ localhost-сервер прокси + фейковый upstream,
// который на ПЕРВОЙ попытке обрывает соединение посреди тела (обещает Content-
// Length, шлёт меньше, закрывает сокет → HttpException у прокси), а на повторе с
// Range честно отдаёт остаток. AES инъектируется детерминированной заглушкой.
//
// Реестр: tests/registry/RL-e2ee-video-proxy-resume.md
// Дизайн: docs/superpowers/specs/2026-08-31-video-playback-mmr-resume-and-history-ledger-design.md
//
// ledger:RL-e2ee-video-proxy-resume
// guard.render: unit

// ignore_for_file: depend_on_referenced_packages

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/e2ee_media_proxy.dart';

int _ivCounter(Uint8List iv) {
  var c = 0;
  for (var i = 8; i < 16; i++) {
    c = (c << 8) | iv[i];
  }
  return c;
}

/// Детерминированная замена AES-CTR (та же, что в e2ee_media_proxy_test): keystream
/// зависит от абсолютного байт-offset. Любой сдвиг counter/выравнивания разъедет
/// расшифровку и покраснит байт-в-байт сверку.
Uint8List _fakeCtr({
  required Uint8List input,
  required Uint8List key,
  required Uint8List iv,
}) {
  final base = _ivCounter(iv) * 16;
  final out = Uint8List(input.length);
  for (var j = 0; j < input.length; j++) {
    final p = base + j;
    // Mix полного offset: прежний линейный XOR повторялся через256 байт
    // и не ловил сброс CTR на resume2048 или смещение IV на16 блоков.
    var mixed = ((p ^ (p >> 16)) * 0x45d9f3b) & 0xffffffff;
    mixed = ((mixed ^ (mixed >> 16)) * 0x45d9f3b) & 0xffffffff;
    mixed ^= mixed >> 16;
    out[j] = input[j] ^ (mixed & 0xff);
  }
  return out;
}

int _rangeStart(String? rangeHeader) {
  if (rangeHeader == null) return 0;
  final m = RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader);
  return m == null ? 0 : int.parse(m.group(1)!);
}

/// Читает всё тело HTTP-ответа в один буфер.
Future<Uint8List> _readAll(HttpClientResponse resp) async {
  final b = <int>[];
  await for (final c in resp) {
    b.addAll(c);
  }
  return Uint8List.fromList(b);
}

void main() {
  late final savedCtr = E2eeMediaProxy.aesCtrImpl;

  setUpAll(() {
    // ignore: unnecessary_statements
    savedCtr;
    E2eeMediaProxy.aesCtrImpl = _fakeCtr;
  });
  tearDownAll(() {
    E2eeMediaProxy.aesCtrImpl = savedCtr;
  });

  tearDown(() async {
    await E2eeMediaProxy.instance.stop();
  });

  // Полезная нагрузка: 8000 байт (кратно и некратно 16 в разных точках обрыва).
  final random = Random(901);
  final plaintext = Uint8List.fromList(
    List.generate(8000, (_) => random.nextInt(256)),
  );
  final encrypted = _fakeCtr(
    input: plaintext,
    key: Uint8List(32),
    iv: Uint8List(16),
  );

  /// Поднимает фейковый upstream. [dropAfter] — сколько байт отдать на КАЖДОЙ из
  /// первых [dropTimes] попыток перед обрывом; дальше — честно до конца.
  /// Возвращает (server, счётчик запросов).
  Future<(HttpServer, List<int>)> fakeUpstream({
    required int dropAfter,
    required int dropTimes,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final reqCount = <int>[0];
    server.listen((req) async {
      reqCount[0]++;
      final start = _rangeStart(req.headers.value('range'));
      final remaining = encrypted.sublist(start);
      if (reqCount[0] <= dropTimes) {
        // Обрыв посреди тела: обещаем полный Content-Length, шлём меньше,
        // рвём сокет → у клиента (прокси) HttpException «closed before full body».
        // writeHeaders:false — сами пишем весь HTTP-ответ, иначе HttpResponse
        // уже отправит chunked-заголовки и наш raw-write разъедется.
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.write('HTTP/1.1 206 Partial Content\r\n');
        socket.write('Content-Length: ${remaining.length}\r\n');
        socket.write(
          'Content-Range: bytes $start-${encrypted.length - 1}'
          '/${encrypted.length}\r\n',
        );
        socket.write('\r\n');
        final n = dropAfter < remaining.length ? dropAfter : remaining.length;
        socket.add(remaining.sublist(0, n));
        await socket.flush();
        await socket.close();
        return;
      }
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers.contentLength = remaining.length;
      req.response.headers.set(
        'content-range',
        'bytes $start-${encrypted.length - 1}/${encrypted.length}',
      );
      req.response.add(remaining);
      await req.response.close();
    });
    return (server, reqCount);
  }

  // AC:RL-e2ee-video-proxy-resume/1
  // AC:RL-video-stream-progress-and-lifecycle/12
  test('AC-1: обрыв upstream на 2048 байт (выровнено) → докачка Range → '
      'полный plaintext, ≥2 запроса к upstream', () async {
    final (upstream, reqCount) = await fakeUpstream(
      dropAfter: 2048,
      dropTimes: 1,
    );
    addTearDown(() => upstream.close(force: true));

    await E2eeMediaProxy.instance.ensureStarted();
    // Регистрируем сессию с реальным downloadUri фейкового upstream.
    final proxyUrl = E2eeMediaProxy.instance.registerRawSessionForTest(
      downloadUri: Uri.parse('http://127.0.0.1:${upstream.port}/media'),
      keyBytes: Uint8List(32),
      ivBytes: Uint8List(16),
      fileSize: plaintext.length,
      sessionId: 'resume-1',
    );
    final client = HttpClient();
    final Uint8List got;
    try {
      final req = await client.getUrl(Uri.parse(proxyUrl));
      got = await _readAll(await req.close());
    } finally {
      client.close(force: true);
    }

    expect(
      got,
      equals(plaintext),
      reason: 'докачка после обрыва должна дать байт-в-байт исходник',
    );
    expect(
      reqCount[0],
      greaterThanOrEqualTo(2),
      reason: 'первый upstream оборвался → минимум один reconnect',
    );
  });

  // AC:RL-e2ee-video-proxy-resume/2
  // AC:RL-video-stream-progress-and-lifecycle/12
  test('AC-2: обрыв на НЕвыровненном смещении (2050, %16!=0) → counter при '
      'докачке остаётся верным', () async {
    final (upstream, reqCount) = await fakeUpstream(
      dropAfter: 2050,
      dropTimes: 1,
    );
    addTearDown(() => upstream.close(force: true));

    await E2eeMediaProxy.instance.ensureStarted();
    final proxyUrl = E2eeMediaProxy.instance.registerRawSessionForTest(
      downloadUri: Uri.parse('http://127.0.0.1:${upstream.port}/media'),
      keyBytes: Uint8List(32),
      ivBytes: Uint8List(16),
      fileSize: plaintext.length,
      sessionId: 'resume-2',
    );
    final client = HttpClient();
    final Uint8List got;
    try {
      final req = await client.getUrl(Uri.parse(proxyUrl));
      got = await _readAll(await req.close());
    } finally {
      client.close(force: true);
    }
    expect(got, equals(plaintext));
    expect(reqCount[0], greaterThanOrEqualTo(2));
  });

  // AC:RL-e2ee-video-proxy-resume/7
  // AC:RL-video-stream-progress-and-lifecycle/12
  test(
    'больше 6 обрывов с валидным прогрессом → весь непериодический plaintext',
    () async {
      final (upstream, reqCount) = await fakeUpstream(
        dropAfter: 700,
        dropTimes: 8,
      );
      addTearDown(() => upstream.close(force: true));
      await E2eeMediaProxy.instance.ensureStarted();
      final url = E2eeMediaProxy.instance.registerRawSessionForTest(
        downloadUri: Uri.parse('http://127.0.0.1:${upstream.port}/media'),
        keyBytes: Uint8List(32),
        ivBytes: Uint8List(16),
        fileSize: plaintext.length,
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final bytes = await _readAll(
        await (await client.getUrl(Uri.parse(url))).close(),
      );
      expect(bytes, plaintext);
      expect(reqCount.single, 9);
    },
  );

  // AC:RL-e2ee-video-proxy-resume/3
  test('AC-3: перманентный обрыв (upstream рвёт ВСЕГДА) → НЕ бесконечный цикл, '
      'запрос завершается за разумное время', () async {
    // dropAfter:0 → каждый ответ отдаёт 0 байт и рвётся (НЕТ прогресса) → счётчик
    // подряд-неудач растёт до _maxUpstreamRetries → терминальная ошибка, а не
    // вечный цикл. (При прогрессе resume докачивал бы — проверено в AC-1/AC-2.)
    final (upstream, reqCount) = await fakeUpstream(
      dropAfter: 0,
      dropTimes: 9999,
    );
    addTearDown(() => upstream.close(force: true));

    await E2eeMediaProxy.instance.ensureStarted();
    final proxyUrl = E2eeMediaProxy.instance.registerRawSessionForTest(
      downloadUri: Uri.parse('http://127.0.0.1:${upstream.port}/media'),
      keyBytes: Uint8List(32),
      ivBytes: Uint8List(16),
      fileSize: plaintext.length,
      sessionId: 'resume-3',
    );
    final client = HttpClient();
    var finished = false;
    try {
      final req = await client.getUrl(Uri.parse(proxyUrl));
      final resp = await req.close();
      // Читаем что придёт — тело будет неполным, но поток ОБЯЗАН завершиться.
      await _readAll(resp);
      finished = true;
    } catch (_) {
      finished = true; // терминальная ошибка — тоже валидное завершение
    } finally {
      client.close(force: true);
    }
    // reset: счётчик подряд-неудач без прогресса упирается в _maxUpstreamRetries.
    expect(finished, isTrue, reason: 'не должно висеть вечно');
    expect(
      reqCount[0],
      lessThan(50),
      reason: 'ограниченное число переоткрытий, не бесконечный цикл',
    );
  }, timeout: const Timeout(Duration(seconds: 20)));
}
