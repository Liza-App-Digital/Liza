// ledger:RL-liza-liquid-page
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/fluid_page_card.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/utils/fluid_page.dart';
import '../../utils/test_client.dart';

/// PNG 1×1 — настоящая картинка, чтобы Image.memory её разобрал.
const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

String img(String alt, {String mime = 'png'}) =>
    '<img src="data:image/$mime;base64,$png" alt="$alt" '
    'style="width:100%">';

String page({int images = 2, String? lead}) =>
    '<!doctype html><html><body><h1>Цвета Santa Fe</h1>'
    '${List.generate(images, (i) => img('Фото $i')).join()}'
    '<p>Фото: автор, CC BY-SA, Wikimedia Commons</p>'
    '<p>Коротко</p>'
    '<p>${lead ?? 'Santa Fe выпускают в восьми цветах кузова, самые '
            'популярные — белый и серый металлик.'}</p>'
    '</body></html>';

/// Виджет-превью страницы в ленте (v5): фото страницы сеткой, название,
/// первый абзац, значок «открыть в окне»; тап — окно ОС.
void main() {
  group('parseFluidPagePreview', () {
    test('фото из data:-src, alt, первый содержательный абзац', () {
      // AC:RL-liza-liquid-page/48
      final preview = parseFluidPagePreview(page(images: 3));
      expect(preview.images, hasLength(3));
      expect(preview.images.first.bytes, base64.decode(png));
      expect(preview.images.map((i) => i.alt), ['Фото 0', 'Фото 1', 'Фото 2']);
      // Подпись «Фото: …» и короткий абзац пропущены.
      expect(preview.summary, startsWith('Santa Fe выпускают'));
    });

    test('не больше четырёх фото; jpeg/webp тоже', () {
      // AC:RL-liza-liquid-page/48
      final html =
          '${List.generate(6, (i) => img('$i')).join()}'
          '${img('j', mime: 'jpeg')}${img('w', mime: 'webp')}';
      final preview = parseFluidPagePreview(html);
      expect(preview.images, hasLength(kFluidPagePreviewMaxImages));
    });

    test('внешние ссылки, svg и битый base64 не берутся', () {
      // AC:RL-liza-liquid-page/48
      const html =
          '<img src="https://evil.example/x.png" alt="сеть">'
          '<img src="data:image/svg+xml;base64,PHN2Zy8+" alt="svg">'
          '<img src="data:image/png;base64,@@@" alt="битый">'
          '<p>Абзац без картинок, но достаточно длинный, чтобы стать '
          'описанием.</p>';
      final preview = parseFluidPagePreview(html);
      expect(preview.images, isEmpty);
      expect(preview.summary, contains('Абзац без картинок'));
    });

    test('HTML-сущности и теги в абзаце снимаются', () {
      // AC:RL-liza-liquid-page/48
      const html =
          '<p>Цвет <b>&quot;Белый&nbsp;кристалл&quot;</b> &amp; '
          '<i>серый</i> — самые частые у дилеров.</p>';
      expect(
        parseFluidPagePreview(html).summary,
        'Цвет "Белый кристалл" & серый — самые частые у дилеров.',
      );
    });

    test('регистр тегов и атрибуты <p> не мешают; <pre>/<param> — не абзац', () {
      // AC:RL-liza-liquid-page/48
      const html =
          '<pre>Код длиной больше сорока символов, но это не абзац текста.</pre>'
          '<P class="lead">Абзац в верхнем регистре, длиной больше сорока '
          'символов.</P >';
      expect(
        parseFluidPagePreview(html).summary,
        'Абзац в верхнем регистре, длиной больше сорока символов.',
      );
    });

    test('незакрытые <p> на большой странице разбираются линейно', () {
      // AC:RL-liza-liquid-page/48
      final html = '<p>коротко ' * 40000;
      final sw = Stopwatch()..start();
      expect(parseFluidPagePreview(html).summary, isEmpty);
      // Прежний ленивый dotAll-regex тут досматривал до конца ~40000 раз (≈4 с).
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });

  group('FluidPageCard', () {
    final manager = MiniAppManager.instance;
    late Client client;
    late Room room;

    Future<void> setup(WidgetTester tester, String html) async {
      await tester.runAsync(() async {
        client = await prepareTestClient(loggedIn: true);
      });
      room = Room(id: '!chat:example.invalid', client: client);
      FluidPageCard.debugClearCache();
      FluidPageCard.debugLoadHtml = (_) async => html;
      manager.closeAll();
      manager.windowsSupported = true;
      addTearDown(() async {
        FluidPageCard.debugLoadHtml = null;
        FluidPageCard.debugClearCache();
        manager.closeAll();
        manager.windowsSupported = false;
        await client.dispose();
      });
    }

    Event pageEvent(String id) => Event.fromJson({
      'type': 'm.room.message',
      'event_id': id,
      'sender': '@bot:example.invalid',
      'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
      'room_id': room.id,
      'content': {
        'msgtype': 'm.file',
        'body': 'Страница: Цвета Santa Fe',
        'info': {'mimetype': 'text/html'},
        'url': 'mxc://example.invalid/abc',
        'com.liza.page': {'title': 'Цвета Santa Fe', 'sha256': 'x'},
      },
    }, room);

    Future<void> pumpCard(WidgetTester tester, Event event) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('ru'),
          home: Scaffold(
            body: Center(
              child: FluidPageCard(event: event, textColor: Colors.black),
            ),
          ),
        ),
      );
      for (
        var i = 0;
        i < 50 &&
            find.byKey(const ValueKey('fluid-page-card')).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }

    for (final n in [1, 2, 3, 4]) {
      testWidgets('$n фото → сетка из $n, значок открытия на сетке', (
        tester,
      ) async {
        // AC:RL-liza-liquid-page/49
        await setup(tester, page(images: n));
        await pumpCard(tester, pageEvent('\$p$n'));
        final grid = find.byKey(const ValueKey('fluid-page-preview-grid'));
        expect(grid, findsOneWidget);
        for (var i = 0; i < n; i++) {
          expect(
            find.byKey(ValueKey('fluid-page-preview-image-$i')),
            findsOneWidget,
          );
        }
        expect(
          find.byKey(ValueKey('fluid-page-preview-image-$n')),
          findsNothing,
        );
        // Фото заполняют сетку целиком: сумма площадей плиток = площадь сетки
        // за вычетом зазоров 2 px (раньше узкое фото сжималось до пропорций и
        // оставляло пустые полосы).
        final g = tester.getRect(grid);
        var area = 0.0;
        for (var i = 0; i < n; i++) {
          final r = tester.getRect(
            find.byKey(ValueKey('fluid-page-preview-image-$i')),
          );
          expect(r.left, greaterThanOrEqualTo(g.left - 0.5));
          expect(r.right, lessThanOrEqualTo(g.right + 0.5));
          area += r.width * r.height;
        }
        expect(
          area / (g.width * g.height),
          greaterThan(0.97),
          reason: 'фото заполняют блок картинок без пустых полос',
        );
        final icon = find.byKey(const ValueKey('fluid-page-open-icon'));
        expect(icon, findsOneWidget);
        expect(
          find.descendant(of: grid, matching: icon),
          findsOneWidget,
          reason: 'значок «открыть в окне» — в блоке картинок',
        );
        expect(find.text('Цвета Santa Fe'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('fluid-page-preview-summary')),
          findsOneWidget,
        );
      });
    }

    testWidgets('текст карточки не прижат к краям: отступ ≥ 12 по бокам', (
      tester,
    ) async {
      // AC:RL-liza-liquid-page/50
      await setup(tester, page(images: 2));
      await pumpCard(tester, pageEvent(r'$pad'));
      final card = tester.getRect(
        find.byKey(const ValueKey('fluid-page-card')),
      );
      for (final text in [
        find.text('Цвета Santa Fe'),
        find.byKey(const ValueKey('fluid-page-preview-summary')),
      ]) {
        final r = tester.getRect(text);
        expect(r.left - card.left, greaterThanOrEqualTo(12));
        expect(card.right - r.right, greaterThanOrEqualTo(12));
      }
    });

    testWidgets('нет фото → заголовок, абзац и значок открытия в подписи', (
      tester,
    ) async {
      // AC:RL-liza-liquid-page/49
      await setup(tester, page(images: 0));
      await pumpCard(tester, pageEvent(r'$p0'));
      expect(
        find.byKey(const ValueKey('fluid-page-preview-grid')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('fluid-page-open-icon')),
        findsOneWidget,
      );
      expect(find.text('Цвета Santa Fe'), findsOneWidget);
    });

    testWidgets('страница не скачалась → карточка с названием, без падения', (
      tester,
    ) async {
      // AC:RL-liza-liquid-page/49
      await setup(tester, '');
      FluidPageCard.debugLoadHtml = (_) async =>
          throw const FluidPageException('download');
      await pumpCard(tester, pageEvent(r'$err'));
      expect(tester.takeException(), isNull);
      expect(find.text('Цвета Santa Fe'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('fluid-page-open-icon')),
        findsOneWidget,
      );
    });

    testWidgets('тап по превью → страница в отдельном окне ОС', (tester) async {
      // AC:RL-liza-liquid-page/51
      await setup(tester, page(images: 4));
      await pumpCard(tester, pageEvent(r'$tap'));
      expect(manager.detachedApps, isEmpty, reason: 'само не открывается');
      await tester.tap(find.byKey(const ValueKey('fluid-page-open-icon')));
      await tester.pump();
      expect(manager.detachedApps, hasLength(1));
      expect(manager.apps, isEmpty, reason: 'справа в окне Лизы пусто');
    });

    testWidgets('повторная сборка карточки не качает страницу заново', (
      tester,
    ) async {
      // AC:RL-liza-liquid-page/52
      await setup(tester, page(images: 2));
      var loads = 0;
      final html = page(images: 2);
      FluidPageCard.debugLoadHtml = (_) async {
        loads++;
        return html;
      };
      final event = pageEvent(r'$cache');
      await pumpCard(tester, event);
      await tester.pumpWidget(const SizedBox());
      await pumpCard(tester, event);
      expect(loads, 1);
      expect(
        find.byKey(const ValueKey('fluid-page-preview-grid')),
        findsOneWidget,
      );
    });
  });
}
