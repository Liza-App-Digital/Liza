import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ledger:RL-group-content-protection

// Task 10, Fix round 2 (2026-07-30): контекстное меню и панель множественного
// выбора (Fix round 1) гейтят копирование/пересылку/сохранение, но остались
// два более широких класса обхода, найденных пользователем:
//
// 1. `SelectionArea` в chat_event_list.dart оборачивала КАЖДОЕ сообщение на
//    desktop/web безусловно — выделение текста мышью + Ctrl+C давало вынос
//    контента в обход всего контекстного меню целиком.
// 2. Инлайн-кнопки скачивания в теле вложений (файл/аудио/видео) стоят
//    отдельно от контекстного меню и от панели множественного выбора.
//
// Различие ВОСПРОИЗВЕДЕНИЕ vs СОХРАНЕНИЕ: просмотр/прослушивание контента в
// защищённом канале не запрещаем (иначе контент нельзя потребить вообще),
// запрещаем только явный вынос на диск.
//
// Структурный тест по исходнику — тот же паттерн, что и в
// multiselect_content_protection_test.dart: полноценная Room/Client в
// unit-окружении неподъёмна, поэтому проверяем точный текст гейта рядом с
// каждой точкой (плюс мутационная проверка, задокументированная в отчёте).
void main() {
  String compact(String path) {
    final file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'Тест должен запускаться из clients/flutter/',
    );
    return file.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
  }

  group('гейт isContentProtected на SelectionArea (выделение мышью)', () {
    test('_selectableMessage получает per-event isContentProtected', () {
      final source = compact('lib/pages/chat/chat_event_list.dart');
      expect(
        source.contains(
          'selectable: !PlatformInfos.isMobile && '
          '!event.room.isContentProtected,',
        ),
        isTrue,
        reason:
            'SelectionArea должна выключаться в защищённом канале — иначе '
            'подписчик выделяет текст поста мышью и копирует Ctrl+C в обход '
            'контекстного меню целиком',
      );
    });
  });

  group('гейт isContentProtected на инлайн-кнопках сохранения', () {
    test('кнопка "Скачать" в message_download_content.dart гейтится', () {
      final source = compact(
        'lib/pages/chat/events/message_download_content.dart',
      );
      expect(
        source.contains(
          'if (!event.room.isContentProtected) IconButton( '
          'onPressed: () => event.saveFile(context),',
        ),
        isTrue,
        reason:
            'инлайн-кнопка скачивания файла должна прятаться при '
            'isContentProtected — она сохраняет вложение мимо контекстного '
            'меню и панели множественного выбора',
      );
    });

    // ⚠️ ПЕРЕСМОТРЕНО 2026-09-04 (LABA-2541). Раньше здесь стояло обратное
    // утверждение — «открытие по тапу НЕ гейтим, это просмотр, а не
    // сохранение». Оно оказалось фактически неверным: `openFile` на web
    // делегирует прямо в `saveFile` (скачивание браузером), а на нативных
    // пишет РАСШИФРОВАННЫЕ байты во временный файл и отдаёт его внешнему
    // приложению, откуда доступны «Сохранить как» и «Поделиться». То есть тап
    // по карточке выносил файл ничуть не меньше кнопки «Скачать» рядом.
    // Потребление контента не страдает: изображения, видео и аудио играются
    // прямо в ленте, а документ в защищённом чате намеренно не выдаётся.
    test('открытие документа по тапу ГЕЙТИТСЯ (openFile тоже выносит файл)', () {
      final source = compact(
        'lib/pages/chat/events/message_download_content.dart',
      );
      expect(
        source.contains(
          'onTap: event.room.isContentProtected ? null '
          ': () => event.openFile(context),',
        ),
        isTrue,
        reason:
            'openFile на web = saveFile, на нативных = расшифрованные байты во '
            'внешнее приложение; без гейта это обход запрета сохранения',
      );
    });

    test('long-press "сохранить" на кнопке play/pause в audio_player.dart гейтится', () {
      final source = compact('lib/pages/chat/events/audio_player.dart');
      expect(
        source.contains(
          'onLongPress: widget.event.room.isContentProtected ? null : () { '
          'HapticFeedback.heavyImpact(); widget.event.saveFile(context); },',
        ),
        isTrue,
        reason:
            'long-press на кнопке плеера сохраняет голосовое/аудио на '
            'устройство — вынос контента мимо меню',
      );
    });

    test('onTap play/pause в audio_player.dart НЕ гейтится (воспроизведение)', () {
      final source = compact('lib/pages/chat/events/audio_player.dart');
      expect(
        source.contains('onTap: _onButtonTap,'),
        isTrue,
        reason:
            'воспроизведение аудио — не вынос контента, должно оставаться '
            'доступным даже в защищённом канале',
      );
    });

    test('fallback-сохранение видео в video_player.dart гейтится', () {
      final source = compact('lib/pages/chat/events/video_player.dart');
      expect(
        source.contains(
          "} else if (!event.room.isContentProtected) { "
          'event.saveFile(context); }',
        ),
        isTrue,
        reason:
            'fallback-ветка (платформа без встроенного видеоплеера) сохраняет '
            'файл на устройство — вынос контента, должен гейтиться',
      );
    });

    // ledger:RL-windows-video-viewer-playback
    // AC:RL-windows-video-viewer-playback/5 — тап по видео при поддержке
    // плеера (теперь и Windows) открывает просмотрщик, а не saveFile.
    test('showDialog просмотра видео в video_player.dart НЕ гейтится (воспроизведение)', () {
      final source = compact('lib/pages/chat/events/video_player.dart');
      expect(
        source.contains('if (supportsVideoPlayer) { showDialog<void>('),
        isTrue,
        reason:
            'открытие встроенного просмотрщика видео — воспроизведение, не '
            'вынос контента, должно оставаться доступным',
      );
    });
  });
}
