// Страж докачки вложений по Range (заявка №56, 2026-10-23).
//
// Корень: matrix-media-repo v1.3.8 рвёт отдачу через 20 с (контекст
// BlockForReadUntil живёт до Close тела) → файл 255 МБ на медленном канале
// падал `Connection closed while receiving data` на каждой попытке, т.к.
// «Скачать» качало одним GET без докачки. Фикс — downloadWithRangeResume.
//
// Фейковый upstream ведёт себя как прод-MMR: на `bytes=N-` отдаёт 206 КУСКОМ
// (не хвостом), может оборвать тело посреди и может проигнорировать Range (200).
//
// Реестр: tests/registry/RL-attachment-download-range-resume.md
// Дизайн: docs/superpowers/specs/2026-10-23-ticket56-large-file-download-mmr-deadline-design.md
//
// ledger:RL-attachment-download-range-resume
// guard.render: unit

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';

final _url = Uri.parse(
  'https://example.org/_matrix/client/v1/media/download/s/m',
);

Uint8List _payload(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 31 + 7) & 0xff));

/// Одна попытка: как ответить на запрос, начинающийся с [start].
typedef _Plan = ({
  int status,
  int? cutAfter, // оборвать тело после стольких байт (ClientException)
  int? chunkCap, // 206: отдать не больше стольких байт (кусок MMR)
  bool ignoreRange, // 200 с полным телом вместо 206
  bool garbageTail, // как MMR: перед обрывом дописать JSON-ошибку в тело
});

_Plan _ok({
  int status = 0,
  int? cutAfter,
  int? chunkCap,
  bool ignoreRange = false,
  bool garbageTail = false,
}) => (
  status: status,
  cutAfter: cutAfter,
  chunkCap: chunkCap,
  ignoreRange: ignoreRange,
  garbageTail: garbageTail,
);

class _FakeMmr extends http.BaseClient {
  _FakeMmr(this.data, this.plans);

  final Uint8List data;
  final List<_Plan> plans;
  final List<String?> ranges = [];
  int defaultChunkCap = 1 << 30;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final range = request.headers['range'];
    ranges.add(range);
    final plan = ranges.length <= plans.length
        ? plans[ranges.length - 1]
        : _ok();
    final start = range == null
        ? 0
        : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);

    if (plan.status >= 400) {
      return http.StreamedResponse(
        Stream.value(Uint8List.fromList('{"errcode":"M_UNKNOWN"}'.codeUnits)),
        plan.status,
        headers: {'content-type': 'application/json'},
      );
    }
    if (range != null && start >= data.length) {
      return http.StreamedResponse(const Stream.empty(), 416);
    }

    final partial = range != null && !plan.ignoreRange;
    final from = partial ? start : 0;
    final cap = plan.chunkCap ?? defaultChunkCap;
    final to = partial
        ? (from + cap < data.length ? from + cap : data.length)
        : data.length;
    final body = data.sublist(from, to);

    final controller = StreamController<List<int>>();
    () async {
      final cut = plan.cutAfter;
      var sent = 0;
      // Отдаём мелкими чанками, чтобы обрыв был посреди потока.
      while (sent < body.length) {
        if (cut != null && sent >= cut) {
          if (plan.garbageTail) controller.add(_mmrPanicJson);
          controller.addError(
            http.ClientException(
              'Connection closed while receiving data',
              _url,
            ),
          );
          await controller.close();
          return;
        }
        final end = sent + 7 < body.length ? sent + 7 : body.length;
        final lim = cut != null && end > cut ? cut : end;
        controller.add(body.sublist(sent, lim));
        sent = lim;
        await Future<void>.delayed(Duration.zero);
      }
      await controller.close();
    }();

    return http.StreamedResponse(
      controller.stream,
      partial ? 206 : 200,
      contentLength: body.length,
      headers: {
        'content-type': 'application/octet-stream',
        if (partial) 'content-range': 'bytes $from-${to - 1}/${data.length}',
      },
    );
  }
}

/// Ровно то, что прод-MMR v1.3.8 дописывает в 200-тело перед обрывом (живой
/// прогон 2026-10-23, 75 байт на смещении обрыва).
final _mmrPanicJson = Uint8List.fromList(
  '{"errcode":"M_UNKNOWN","error":"unexpected error","mr_errcode":"M_UNKNOWN"}'
      .codeUnits,
);

Future<Uint8List> _download(
  _FakeMmr client, {
  List<int>? progress,
  int maxRetries = 6,
  int rewind = 16,
}) => downloadWithRangeResume(
  client: client,
  url: _url,
  accessToken: 'tok',
  onProgress: progress?.add,
  maxRetriesWithoutProgress: maxRetries,
  resumeRewindBytes: rewind,
  backoff: (_) => Duration.zero,
);

void main() {
  group('downloadWithRangeResume (ledger:RL-attachment-download-range-resume)', () {
    // AC:RL-attachment-download-range-resume/1
    test(
      'AC-1: обрыв посреди / ×3 подряд / на 0 байт → итог байт-в-байт',
      () async {
        final data = _payload(1000);
        final cases = <String, List<_Plan>>{
          'посреди, невыровненно': [_ok(cutAfter: 333)],
          'три обрыва подряд с прогрессом': [
            _ok(cutAfter: 101),
            _ok(cutAfter: 250),
            _ok(cutAfter: 3),
          ],
          'обрыв на 0 байт': [_ok(cutAfter: 0), _ok(cutAfter: 0)],
        };
        for (final entry in cases.entries) {
          final client = _FakeMmr(data, entry.value);
          final got = await _download(client);
          expect(got, data, reason: entry.key);
        }
      },
    );

    // AC:RL-attachment-download-range-resume/2
    test('AC-2: повтор просит Range ровно от полученного байта', () async {
      final data = _payload(500);
      final client = _FakeMmr(data, [_ok(cutAfter: 123), _ok(cutAfter: 77)]);
      await _download(client, rewind: 0);
      expect(client.ranges, [null, 'bytes=123-', 'bytes=200-']);
      // С откатом — от полученного минус откат (мусорный хвост перекачивается).
      final rewound = _FakeMmr(data, [_ok(cutAfter: 123), _ok(cutAfter: 77)]);
      await _download(rewound, rewind: 16);
      expect(rewound.ranges, [null, 'bytes=107-', 'bytes=168-']);
    });

    // AC:RL-attachment-download-range-resume/3
    test(
      'AC-3: 206 кусок короче хвоста (как MMR 10 МБ) → качает до total',
      () async {
        final data = _payload(1000);
        final client = _FakeMmr(data, [_ok(cutAfter: 50)])
          ..defaultChunkCap = 128;
        final got = await _download(client);
        expect(got, data);
        // 50 + 8 кусков по 128 (последний неполный) → 1 + 8 запросов.
        expect(client.ranges.length, 9);
      },
    );

    // AC:RL-attachment-download-range-resume/4
    test('AC-4: сервер проигнорировал Range (200) → не склеивает', () async {
      final data = _payload(600);
      final client = _FakeMmr(data, [
        _ok(cutAfter: 200),
        _ok(ignoreRange: true),
      ]);
      final got = await _download(client);
      expect(got, data);
      expect(got.length, 600);
    });

    // AC:RL-attachment-download-range-resume/5
    test(
      'AC-5: обрывы без прогресса → терминальная ошибка, без вечного цикла',
      () async {
        final data = _payload(400);
        final client = _FakeMmr(data, [
          _ok(cutAfter: 100),
          for (var i = 0; i < 10; i++) _ok(cutAfter: 0),
        ]);
        await expectLater(
          _download(client, maxRetries: 3),
          throwsA(isA<http.ClientException>()),
        );
        // Обрыв после прогресса = 1-я неудача; ещё 3 без прогресса → 4-я
        // превышает лимит 3 → терминал. Итого 4 запроса.
        expect(client.ranges.length, 4);
      },
    );

    // AC:RL-attachment-download-range-resume/6
    test('AC-6: прогресс не убывает и кончается размером файла', () async {
      final data = _payload(800);
      for (final plans in [
        [_ok(cutAfter: 300)],
        [_ok(cutAfter: 300), _ok(ignoreRange: true)],
        [_ok(cutAfter: 10), _ok(cutAfter: 0), _ok(cutAfter: 500)],
      ]) {
        final progress = <int>[];
        await _download(_FakeMmr(data, plans), progress: progress);
        for (var i = 1; i < progress.length; i++) {
          expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
        }
        expect(progress.last, data.length);
      }
    });

    // AC:RL-attachment-download-range-resume/7
    test(
      'AC-7: ≥400 на повторе → MediaDownloadException, без докачки',
      () async {
        final data = _payload(400);
        final client = _FakeMmr(data, [_ok(cutAfter: 100), _ok(status: 404)]);
        await expectLater(
          _download(client),
          throwsA(
            isA<MediaDownloadException>().having(
              (e) => e.statusCode,
              'status',
              404,
            ),
          ),
        );
        expect(client.ranges.length, 2);
      },
    );

    test(
      'первый ответ ≥400 читается как есть — гейт решает вызывающий',
      () async {
        final client = _FakeMmr(_payload(10), [_ok(status: 404)]);
        final got = await _download(client);
        expect(String.fromCharCodes(got), contains('errcode'));
        expect(client.ranges.length, 1);
      },
    );

    // AC:RL-attachment-download-range-resume/8
    test(
      'AC-8: JSON-ошибка MMR в хвосте перед обрывом не попадает в файл',
      () async {
        final data = _payload(5000);
        for (final plans in [
          [_ok(cutAfter: 1234, garbageTail: true)],
          [
            _ok(cutAfter: 700, garbageTail: true),
            _ok(cutAfter: 900, garbageTail: true),
            _ok(cutAfter: 50, garbageTail: true),
          ],
        ]) {
          final got = await _download(_FakeMmr(data, plans), rewind: 128);
          expect(got, data);
        }
        // Без отката мусор вклеивается — ровно баг живого прогона (размер верный).
        final broken = await _download(
          _FakeMmr(data, [_ok(cutAfter: 1234, garbageTail: true)]),
          rewind: 0,
        );
        expect(broken.length, data.length);
        expect(broken, isNot(data));
      },
    );

    // AC:RL-attachment-download-range-resume/6
    test(
      'AC-6b: во время перекачки отката прогресс звучит (признак жизни)',
      () async {
        final data = _payload(3000);
        final progress = <int>[];
        // Откат 512 Б: после обрыва на 1000 перекачиваются 488..999 — новых максимумов
        // нет, но onProgress обязан звучать (им кормится дедлайн простоя голосовых).
        await _download(
          _FakeMmr(data, [_ok(cutAfter: 1000)]),
          progress: progress,
          rewind: 512,
        );
        expect(progress.where((p) => p == 1000).length, greaterThan(1));
        expect(progress.last, data.length);
      },
    );

    // AC:RL-attachment-download-range-resume/5
    test(
      'AC-5b: пустые 206 без прогресса → терминал, не вечный цикл',
      () async {
        final data = _payload(400);
        // Обрыв на 100, затем сервер отвечает 206-кусками нулевой длины.
        final client = _FakeMmr(data, [_ok(cutAfter: 100)])
          ..defaultChunkCap = 0;
        await expectLater(
          _download(client, maxRetries: 3, rewind: 0),
          throwsA(isA<http.ClientException>()),
        );
        expect(client.ranges.length, lessThanOrEqualTo(6));
      },
    );

    test('parseContentRange', () {
      expect(parseContentRange('bytes 200000000-210485759/255106903'), (
        start: 200000000,
        total: 255106903,
      ));
      expect(parseContentRange('bytes 0-9/*'), (start: 0, total: null));
      expect(parseContentRange('items 0-9/10'), isNull);
      expect(parseContentRange(null), isNull);
    });
  });
}
