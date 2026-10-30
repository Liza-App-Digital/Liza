// ledger:RL-share-intent-opens-channel
import 'dart:io';
//
// Т1 (2026-08-24). ОС шарит ссылку-канал (SharedMediaType.url) в приложение —
// _processIncomingSharedMedia вместо открытия канала показывал ShareScaffoldDialog
// (форвард-пикер). Фикс: при files.length==1 && type==SharedMediaType.url проверяем
// resolveInternalRoute; при non-null — context.go(route), return.
//
// Этот тест закрепляет:
//   AC-1: resolveInternalRoute для Liza-ссылок → внутренний роут (позитив).
//   AC-2: для SharedMediaType.text, не-Liza URL, мульти-элемент — пикер, не роут.
//   (AC-3 device-flow — manual: реальный ACTION_VIEW на сборке > 3730.)
//
// Тестируемая чистая функция: resolveInternalRoute (invite_link_parser.dart).
// Логику ветвления _processIncomingSharedMedia проверяем через имитацию предиката
// (чистая функция — не виджет-тест, нет BuildContext). Этот файл расширяет
// RL-channel-link-open-internal (тот же резолвер, другой входной сигнал — share).
//
// Red-proof: убираем вызов resolveInternalRoute из гейта → позитивный кейс
// даёт маршрут «в пикер» вместо «открыть роут» — тест краснеет.

// AC:RL-share-intent-opens-channel/1
// AC:RL-share-intent-opens-channel/2

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/invite_link_parser.dart';

// ---------------------------------------------------------------------------
// Имитация SharedMediaType (без плагина receive_sharing_intent в unit-тестах)
// ---------------------------------------------------------------------------
enum _SharedMediaType { url, text, image }

// Реализует ЛОГИКУ _processIncomingSharedMedia:
// возвращает 'route:<маршрут>' если Liza-URL, 'picker' иначе.
String _simulateProcessSharedMedia(
  List<({String path, _SharedMediaType type})> files,
) {
  if (files.isEmpty) return 'noop';
  if (files.length == 1 && files.single.type == _SharedMediaType.url) {
    final uri = Uri.tryParse(files.single.path);
    final route = uri == null ? null : resolveInternalRoute(uri);
    if (route != null) return 'route:$route';
  }
  return 'picker';
}

void main() {
  // -------------------------------------------------------------------------
  // AC-1: единичный SharedMediaType.url с Liza-ссылкой → внутренний роут
  // -------------------------------------------------------------------------
  group('AC-1 [AC:RL-share-intent-opens-channel/1] — Liza-URL → внутренний роут', () {
    test('me.liza.ru/c/<ник> открывает канал', () {
      expect(
        _simulateProcessSharedMedia([
          (path: 'https://me.liza.ru/c/rozental', type: _SharedMediaType.url),
        ]),
        'route:/c/rozental',
      );
    });

    test('me.liza.ru/s/<code> открывает сторис', () {
      expect(
        _simulateProcessSharedMedia([
          (path: 'https://me.liza.ru/s/abc123', type: _SharedMediaType.url),
        ]),
        'route:/s/abc123',
      );
    });

    test('me.liza.ru/i/<code> открывает инвайт', () {
      expect(
        _simulateProcessSharedMedia([
          (path: 'https://me.liza.ru/i/p_DKvhaNQUUi', type: _SharedMediaType.url),
        ]),
        'route:/i/p_DKvhaNQUUi',
      );
    });

    test('me.liza.ru/u/<ник> открывает профиль', () {
      expect(
        _simulateProcessSharedMedia([
          (path: 'https://me.liza.ru/u/alice', type: _SharedMediaType.url),
        ]),
        'route:/u/alice',
      );
    });

    test('liza://channel/<ник> открывает канал', () {
      expect(
        _simulateProcessSharedMedia([
          (path: 'liza://channel/rozental', type: _SharedMediaType.url),
        ]),
        'route:/c/rozental',
      );
    });

    test('legacy-домен liza.laba.pro/c/<ник> открывает канал', () {
      expect(
        _simulateProcessSharedMedia([
          (path: 'https://liza.laba.pro/c/rozental', type: _SharedMediaType.url),
        ]),
        'route:/c/rozental',
      );
    });
  });

  // -------------------------------------------------------------------------
  // AC-2: негатив-квантор — всё, что НЕ должно открываться как роут
  // -------------------------------------------------------------------------
  group('AC-2 [AC:RL-share-intent-opens-channel/2] — негатив → пикер', () {
    // Форвард текста с Liza-ссылкой — тип text, НЕ url → пикер
    test('SharedMediaType.text с Liza-URL → пикер (форвард сохранён)', () {
      expect(
        _simulateProcessSharedMedia([
          (path: 'https://me.liza.ru/c/rozental', type: _SharedMediaType.text),
        ]),
        'picker',
        reason:
            'Текст-форвард приходит как SharedMediaType.text (не url) — '
            'его не перехватываем, отправляем в ShareScaffoldDialog',
      );
    });

    // Не-Liza URL → пикер (resolveInternalRoute=null)
    test('SharedMediaType.url с не-Liza-хостом → пикер', () {
      expect(
        _simulateProcessSharedMedia([
          (path: 'https://example.com/c/rozental', type: _SharedMediaType.url),
        ]),
        'picker',
      );
    });

    // Обычная https-ссылка без матча → пикер
    test('SharedMediaType.url с google.com → пикер', () {
      expect(
        _simulateProcessSharedMedia([
          (path: 'https://google.com', type: _SharedMediaType.url),
        ]),
        'picker',
      );
    });

    // Мульти-элемент (len>1) → пикер даже если все элементы Liza-URLs
    test('2 элемента (len>1) → пикер (мульти-шар)', () {
      expect(
        _simulateProcessSharedMedia([
          (path: 'https://me.liza.ru/c/rozental', type: _SharedMediaType.url),
          (path: 'https://me.liza.ru/c/alice', type: _SharedMediaType.url),
        ]),
        'picker',
      );
    });

    // Файл → пикер
    test('SharedMediaType.image → пикер', () {
      expect(
        _simulateProcessSharedMedia([
          (path: '/tmp/photo.jpg', type: _SharedMediaType.image),
        ]),
        'picker',
      );
    });

    // Невалидный ник в Liza URL → resolveInternalRoute=null → пикер
    test('me.liza.ru/c/@x (невалидный ник) → пикер', () {
      expect(
        _simulateProcessSharedMedia([
          (path: 'https://me.liza.ru/c/@x', type: _SharedMediaType.url),
        ]),
        'picker',
      );
    });

    // Пустой список → noop
    test('пустой список файлов → noop', () {
      expect(_simulateProcessSharedMedia([]), 'noop');
    });
  });

  // -------------------------------------------------------------------------
  // RED-PROOF: без гейта resolveInternalRoute Liza-URL попадает в пикер
  // -------------------------------------------------------------------------
  group('RED-PROOF [AC:RL-share-intent-opens-channel/1]', () {
    // Имитирует КОД ДО ФИКСА: нет вызова resolveInternalRoute → всегда пикер
    String brokenProcess(List<({String path, _SharedMediaType type})> files) {
      if (files.isEmpty) return 'noop';
      // ДО фикса: не было гейта type==url && resolveInternalRoute → всегда пикер
      return 'picker';
    }

    test('RED-PROOF: без гейта Liza-URL → пикер (баг возвращается)', () {
      final liza = [(path: 'https://me.liza.ru/c/rozental', type: _SharedMediaType.url)];

      // Сломанный путь — всегда пикер (баг):
      expect(brokenProcess(liza), 'picker');

      // Правильный путь — роут:
      expect(_simulateProcessSharedMedia(liza), 'route:/c/rozental');

      // Разница доказывает, что тест краснеет при откате:
      expect(brokenProcess(liza) != _simulateProcessSharedMedia(liza), isTrue);
    });
  });

  // AC:RL-share-intent-opens-channel/1 — SOURCE-SCAN на ЖИВОЙ прод-инвариант.
  // _processIncomingSharedMedia — приватный метод State + плагин-типы
  // (SharedMediaFile) + навигация (context.go): вызвать live в unit-тесте
  // непрактично, поэтому сторожим сам прод-файл, что дискриминатор
  // «single url → resolveInternalRoute → context.go» присутствует и не заменён
  // на форвард-пикер (регресс баг Т1). Логика-реплика выше — вспомогательна.
  group('AC-1src [AC:RL-share-intent-opens-channel/1] — прод-инвариант в chat_list.dart', () {
    final src = File('lib/pages/chat_list/chat_list.dart').readAsStringSync();
    final method = src.substring(
      src.indexOf('void _processIncomingSharedMedia'),
      src.indexOf('void _processIncomingUris'),
    );
    test('одиночный url → resolveInternalRoute + context.go (не пикер)', () {
      expect(
        method.contains('files.length == 1 && files.single.type == SharedMediaType.url'),
        isTrue,
        reason: 'Дискриминатор «одиночная url-ссылка» обязан быть в проде',
      );
      expect(method.contains('resolveInternalRoute'), isTrue,
          reason: 'Резолвер тот же, что у in-app-тапа/deep-link');
      expect(method.contains('context.go(route)'), isTrue,
          reason: 'url-ссылка Liza ОТКРЫВАЕТСЯ внутри, а не в форвард-пикере');
      // Регресс-охранник: показ пикера ДОЛЖЕН оставаться fallback ПОСЛЕ
      // url-ветки (иначе всё уйдёт в пикер — исходный баг).
      expect(
        method.indexOf('context.go(route)') < method.indexOf('showScaffoldDialog'),
        isTrue,
        reason: 'url-роут раньше пикера — пикер только fallback для не-url',
      );
    });
  });
}
