import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/image_viewer/video_first_frame_gate.dart';

// Гейт первого кадра просмотрщика видео (заявка №52, Android): «Долго грузится
// видео на андроид при старте, кажется, как будто всё зависло. Если там идёт
// прогрузка, то стоит добавить знак прогрузки». До первого кадра — постер +
// индикатор загрузки, а не чёрный `Video` с «паузой» и 0:00/0:00.
//
// Реальный `Player` на host не поднять (нативные биндинги media_kit), поэтому
// условие гейта — чистая функция, а его подключение сторожит source-scan.
// Живой рендер — ручной пункт AC-9 (Android, E2EE WebM без Cues).
//
// ledger:RL-video-first-frame-loading-gate

const _playerPath = 'lib/pages/image_viewer/video_player.dart';

String _normalize(String source) => source.replaceAll(RegExp(r'\s+'), ' ');

bool _open({
  int? width,
  Duration position = Duration.zero,
  bool paused = false,
  bool deadline = false,
}) => firstFrameGateOpen(
  width: width,
  position: position,
  pausedByViewer: paused,
  deadlinePassed: deadline,
);

void main() {
  group('условие гейта', () {
    test('AC:RL-video-first-frame-loading-gate/1 — без кадра, позиции, паузы и '
        'дедлайна гейт закрыт (width null и 0)', () {
      for (final width in [null, 0]) {
        expect(_open(width: width), isFalse, reason: 'width=$width');
      }
    });

    test('AC:RL-video-first-frame-loading-gate/2 — первый кадр открывает гейт '
        'при любой позиции', () {
      for (final pos in [Duration.zero, const Duration(seconds: 3)]) {
        expect(_open(width: 576, position: pos), isTrue, reason: 'pos=$pos');
      }
    });

    test(
      'AC:RL-video-first-frame-loading-gate/3 — без видеодорожки звук идёт → '
      'открыт',
      () {
        expect(_open(position: const Duration(milliseconds: 40)), isTrue);
      },
    );

    test('AC:RL-video-first-frame-loading-gate/4 — пауза свайпом карусели до '
        'кадра → открыт (кнопка play, не вечная крутилка)', () {
      expect(_open(paused: true), isTrue);
    });

    test('AC:RL-video-first-frame-loading-gate/5 — дедлайн → открыт, и он '
        'позже watchdog E2EE (15 с) и stalled-детектора (16 с)', () {
      expect(_open(deadline: true), isTrue);
      expect(firstFrameGateDeadline, greaterThan(const Duration(seconds: 16)));
    });
  });

  test('AC:RL-video-first-frame-loading-gate/6 — гейт подключён: showVideo '
      'требует кадра, каждый open идёт через взвод гейта', () {
    final file = File(_playerPath);
    expect(file.existsSync(), isTrue, reason: 'запускать из clients/flutter/');
    final source = _normalize(file.readAsStringSync());

    expect(
      source,
      contains(
        'final showVideo = _started && _ready && !_swappingToLocal && '
        '_frameShown;',
      ),
    );
    // Единственный прямой open — внутри хелпера, взводящего гейт заново.
    expect(
      RegExp(r'await _player\.open\(').allMatches(source).length,
      1,
      reason: 'новый open в обход _openWatchingFirstFrame оставит чужой кадр',
    );
    expect(
      RegExp(r'await _openWatchingFirstFrame\(').allMatches(source).length,
      greaterThanOrEqualTo(5),
      reason: 'prefetch, стрим, E2EE-прокси, web-blob, локальный файл',
    );
    // Completer одноразовый на контроллер: после свапа/«Повторить» соврёт.
    expect(source, isNot(contains('waitUntilFirstFrameRendered')));
  });
}
