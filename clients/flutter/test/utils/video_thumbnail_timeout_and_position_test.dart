import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/resize_video.dart';

/// ledger:RL-video-thumbnail-timeout-and-position
///
/// Баг (внесён 2026-07-30 коммитом `449c5504`, найден 2026-09-04):
/// `getVideoThumbnail` делал повтор `VideoCompress.getByteThumbnail(position: 1000)`
/// с комментарием «повтор на ~1с». Единица аргумента `position` у плагина
/// РАЗНАЯ на платформах, а его dartdoc («position is milliseconds») врёт на
/// обеих:
///
/// - **Android** — микросекунды (`getFrameAtTime(position, OPTION_CLOSEST_SYNC)`):
///   `1000` = 1 мс, `OPTION_CLOSEST_SYNC` снапит на тот же keyframe, что и
///   позиция 0 → повтор был чистым no-op. Отсюда `len=0` три раза из трёх в
///   логе с Samsung S24.
/// - **iOS** — секунды (`CMTimeMakeWithSeconds(Float64(position))`):
///   `1000` = 1000 СЕКУНД, за концом почти любого ролика → `copyCGImage` = nil.
///   А `SwiftVideoCompressPlugin.getByteThumbnail` — это
///   `if let bitmap = getBitMap(...) { result(bitmap) }` БЕЗ ветки `else`, то
///   есть при nil `FlutterResult` не вызывается никогда → Future метод-канала
///   не завершается ни успехом, ни ошибкой → **`_send()` виснет навсегда**:
///   видео не уходит, ошибки нет, экран пустой.
///
/// Реестр `RL-video-thumbnail-decode-gate` утверждал обратное («завершается
/// только на non-nil, поэтому зависания нет») — эта запись исправляет ошибку.
void main() {
  group('AC:RL-video-thumbnail-timeout-and-position/8 — единицы position', () {
    test('iOS получает позицию в СЕКУНДАХ (≈1 с)', () {
      expect(videoThumbnailRetryPositionFor(TargetPlatform.iOS), 1);
    });

    test('Android получает позицию в МИКРОсекундах (≈1 с)', () {
      expect(videoThumbnailRetryPositionFor(TargetPlatform.android), 1000000);
    });

    test('прежний литерал 1000 не годится ни одной платформе (red-proof)', () {
      // Возврат к общему литералу `1000` красит этот тест: на iOS это 1000 с
      // (хэнг), на Android — 1 мс (повтор впустую).
      expect(videoThumbnailRetryPositionFor(TargetPlatform.iOS), isNot(1000));
      expect(
        videoThumbnailRetryPositionFor(TargetPlatform.android),
        isNot(1000),
      );
    });

    test('позиция повтора уводит с кадра 0 на ОБЕИХ платформах', () {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
        expect(
          videoThumbnailRetryPositionFor(platform),
          greaterThan(0),
          reason: 'повтор в позиции 0 бессмыслен — это первый заход',
        );
      }
    });
  });

  group('AC:RL-video-thumbnail-timeout-and-position/9 — таймаут против хэнга',
      () {
    test('никогда не отвечающий нативный вызов → null, а не вечный await',
        () async {
      // Точная модель iOS-плагина: `result(...)` не вызывается никогда.
      final neverCompletes = Completer<Uint8List?>();
      final result = await videoThumbnailFrameGuarded(
        () => neverCompletes.future,
        timeout: const Duration(milliseconds: 50),
      );
      expect(result, isNull);
    }, timeout: const Timeout(Duration(seconds: 5)));
    // red-proof: убрать `.timeout` в videoThumbnailFrameGuarded — тест
    // не «упадёт с ошибкой», а повиснет и будет убит этим Timeout.

    test('бросающий нативный вызов → null, отправка продолжается', () async {
      final result = await videoThumbnailFrameGuarded(
        () => Future<Uint8List?>.error(StateError('corrupt video file')),
      );
      expect(result, isNull);
    });

    test('валидный вызов проходит насквозь без искажения', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final result = await videoThumbnailFrameGuarded(
        () async => bytes,
      );
      expect(result, same(bytes));
    });

    test('дефолтный таймаут задан и конечен', () {
      expect(videoThumbnailTimeout, isNotNull);
      expect(videoThumbnailTimeout.inSeconds, inInclusiveRange(1, 10));
    });
  });

  group('AC:RL-media-send-instant-bubble/5 — стухший прогресс компрессии', () {
    // `compressProgress$` построен на НЕ-broadcast StreamController: события,
    // пришедшие без подписчика, буферизуются и вываливаются первому же listen.
    // Последнее значение любого завершившегося транскода — ровно 100.0
    // (`VideoCompressPlugin.onTranscodeCompleted`). Наблюдаемый эффект без
    // фильтра: «Сжатие видео… 100%» через 0.2 с после тапа «Прислать».
    test('хвостовые 100% ДО первого реального тика — отбрасываются', () {
      expect(
        isStaleCompressTick(sawRealTick: false, percent: 100),
        isTrue,
        reason: 'это хвост предыдущей компрессии, не своей',
      );
    });

    test('100% ПОСЛЕ реальных тиков — законное завершение своей компрессии', () {
      expect(isStaleCompressTick(sawRealTick: true, percent: 100), isFalse);
    });

    test('своя компрессия всегда начинается со значения < 100 — пропускаем', () {
      for (final percent in [0.0, 0.5, 37.0, 99.9]) {
        expect(
          isStaleCompressTick(sawRealTick: false, percent: percent),
          isFalse,
          reason: '$percent% — реальный старт своей компрессии',
        );
      }
    });
  });
}
