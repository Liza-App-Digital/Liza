import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/fluid_page_building_view.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/utils/fluid_page.dart';

import '../../utils/test_client.dart';

/// Страж видимого хода сборки «жидкой» страницы: карточка-обещание в ленте
/// показывает этапы и таймер, но ничего не открывает — ни сама, ни по тапу
/// (с 10.11 справа ничего не появляется, страница — по клику окном ОС).
/// ledger:RL-liza-liquid-page
void main() {
  late Client client;
  late Room room;
  const bot = '@bot:example.invalid';
  final manager = MiniAppManager.instance;

  setUpAll(() async {
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!chat:example.invalid', client: client);
  });
  setUp(manager.closeAll);

  Event promise(
    String id, {
    String stage = 'answer',
    String sender = bot,
    DateTime? ts,
    int? started,
  }) => Event.fromJson({
    'type': 'm.room.message',
    'event_id': id,
    'sender': sender,
    'origin_server_ts': (ts ?? DateTime.now()).millisecondsSinceEpoch,
    'room_id': room.id,
    'content': {
      'msgtype': 'm.text',
      'body': 'Собираю наглядную страницу',
      kFluidPagePendingKey: {
        'stage': stage,
        'started': started ?? DateTime.now().millisecondsSinceEpoch,
      },
    },
  }, room);

  /// Правка обещания так, как её шлёт бот (сырое событие живого sync).
  Event stageEdit(String id, String of, String stage, {int? started}) {
    final marker = {
      'stage': stage,
      'of': of,
      'started': started ?? DateTime.now().millisecondsSinceEpoch,
    };
    final newContent = {
      'msgtype': 'm.text',
      'body': stage,
      kFluidPagePendingKey: marker,
    };
    return Event.fromJson({
      'type': 'm.room.message',
      'event_id': id,
      'sender': bot,
      'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
      'room_id': room.id,
      'content': {
        ...newContent,
        'body': '* $stage',
        'm.new_content': newContent,
        'm.relates_to': {'rel_type': 'm.replace', 'event_id': of},
      },
    }, room);
  }

  const html = '<!doctype html><html><body>фото</body></html>';
  Event page(String id, {String? pending}) => Event.fromJson({
    'type': 'm.room.message',
    'event_id': id,
    'sender': bot,
    'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
    'room_id': room.id,
    'content': {
      'msgtype': 'm.file',
      'body': 'Страница: Цвета',
      'info': {'mimetype': 'text/html'},
      'url': 'mxc://example.invalid/abc',
      'com.liza.page': {
        'title': 'Цвета',
        'sha256': sha256.convert(utf8.encode(html)).toString(),
        'pending': ?pending,
      },
    },
  }, room);

  group('маркер хода сборки', () {
    test('обещание, правка, display-событие; не обещание — null', () {
      // AC:RL-liza-liquid-page/31
      final p = fluidPagePending(promise(r'$pr1'))!;
      expect(p.id, r'$pr1');
      expect(p.stage, FluidPageStage.answer);
      final edit = fluidPagePending(stageEdit(r'$ed1', r'$pr1', 'photos'))!;
      expect(edit.id, r'$pr1');
      expect(edit.stage, FluidPageStage.photos);
      // display-событие SDK: content = m.new_content, eventId = id правки.
      final display = Event.fromJson({
        'type': 'm.room.message',
        'event_id': r'$ed2',
        'sender': bot,
        'origin_server_ts': 0,
        'room_id': room.id,
        'content': {
          'msgtype': 'm.text',
          'body': 'x',
          kFluidPagePendingKey: {'stage': 'layout', 'of': r'$pr1'},
        },
      }, room);
      expect(fluidPagePending(display)!.id, r'$pr1');
      expect(fluidPagePending(promise(r'$pr2', stage: 'unknown')), isNull);
      expect(fluidPagePending(page(r'$pg0')), isNull);
      expect(fluidPagePendingOf(page(r'$pg0', pending: r'$pr1')), r'$pr1');
    });

    test('незавершённое дольше 6 мин — сорвалось; завершённое — как есть', () {
      // AC:RL-liza-liquid-page/31
      final old = DateTime.now()
          .subtract(const Duration(minutes: 7))
          .millisecondsSinceEpoch;
      final now = DateTime.now();
      expect(
        fluidPagePending(promise(r'$st1', started: old))!.stageAt(now),
        FluidPageStage.failed,
      );
      expect(
        fluidPagePending(
          promise(r'$st2', stage: 'done', started: old),
        )!.stageAt(now),
        FluidPageStage.done,
      );
      expect(
        fluidPagePending(promise(r'$st3'))!.stageAt(now),
        FluidPageStage.answer,
      );
    });
  });

  Widget app(Widget child) => MaterialApp(
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: const Locale('ru'),
    home: Scaffold(body: child),
  );

  /// Делегаты L10n грузятся настоящим async — до них дерево пустое;
  /// pumpAndSettle не годится: крутилка этапа анимируется бесконечно.
  Future<void> settleL10n(WidgetTester tester) async {
    for (var i = 0; i < 50 && find.byType(Scaffold).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder stepRunning(String step) => find.descendant(
    of: find.byKey(ValueKey('fluid-page-step-$step')),
    matching: find.byKey(const ValueKey('fluid-page-step-running')),
  );

  group('рендер', () {
    testWidgets('карточка в ленте: ∀ этапов — свой вид, тап ничего не '
        'открывает', (tester) async {
      // AC:RL-liza-liquid-page/36
      // AC:RL-liza-liquid-page/39
      Future<void> show(FluidPageStage stage, {DateTime? started}) async {
        await tester.pumpWidget(
          app(
            FluidPageProgressCard(
              pending: FluidPagePending(
                id: r'$k1',
                stage: stage,
                started: started ?? DateTime.now(),
              ),
              textColor: Colors.black,
            ),
          ),
        );
        await settleL10n(tester);
      }

      for (final stage in kFluidPageSteps) {
        await show(stage);
        expect(stepRunning(stage.name), findsOneWidget);
        expect(find.text('Собираю страницу'), findsOneWidget);
        await tester.tap(find.text('Собираю страницу'));
      }
      expect(manager.hasApps, isFalse, reason: 'панель «собираю» упразднена');

      await show(FluidPageStage.done);
      expect(find.text('Страница готова'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('fluid-page-progress-done')),
        findsOneWidget,
      );
      await tester.tap(find.text('Страница готова'));

      await show(FluidPageStage.failed);
      expect(
        find.text('Страницу собрать не получилось — ответ в чате'),
        findsOneWidget,
      );

      // Бот упал посреди сборки — через 6 минут карточка не крутится вечно.
      await show(
        FluidPageStage.layout,
        started: DateTime.now().subtract(const Duration(minutes: 7)),
      );
      expect(
        find.byKey(const ValueKey('fluid-page-progress-failed')),
        findsOneWidget,
      );
      expect(manager.hasApps, isFalse);
    });
  });

  test('страница с фото до 1,5 МБ принимается', () async {
    // AC:RL-liza-liquid-page/14
    final big = Uint8List.fromList(
      utf8.encode('<html>${'x' * 1400000}</html>'),
    );
    final p = Event.fromJson({
      ...page(r'$big').toJson(),
      'content': {
        ...page(r'$big').content,
        'com.liza.page': {
          'title': 'Цвета',
          'sha256': sha256.convert(big).toString(),
        },
      },
    }, room);
    expect(
      (await loadFluidPageHtml(p, download: (_) async => big)).length,
      big.length,
    );
  });
}
