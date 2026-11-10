import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/fluid_page_card.dart';
import 'package:liza/pages/chat/fluid_page_building_view.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/utils/fluid_page.dart';

import '../../utils/test_client.dart';

/// Страж видимого хода сборки «жидкой» страницы (v3): обещание бота сразу
/// открывает справа панель «собираю» с этапами и таймером, этапы её
/// обновляют, готовая страница встаёт на её место; закрытая вручную панель
/// не возвращается; карточка в ленте показывает этапы.
/// ledger:RL-liza-liquid-page
void main() {
  late Client client;
  late Room room;
  const bot = '@bot:example.invalid';
  bool isBot(String id) => id == bot;
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

  final openedAt = DateTime.now();

  /// Тот же путь, что подписка ChatController на живой sync.
  void live(Event e, {bool side = true}) {
    final p = liveFluidPagePending(
      event: e,
      roomId: room.id,
      openedAt: openedAt,
      isBotOrAiUser: isBot,
    );
    if (p == null) return;
    applyLiveFluidPagePending(p, event: e, sideLayout: side, title: 'Собираю');
  }

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

  group('панель «собираю» справа', () {
    test('обещание сразу открывает панель ровно один раз, этапы её ведут', () {
      // AC:RL-liza-liquid-page/32
      live(promise(r'$a1'));
      expect(manager.activeApp?.appId, kFluidPageAppId);
      expect(manager.activeApp?.pageEvent, isNull);
      expect(manager.showsPending(r'$a1'), isTrue);
      expect(manager.pageBuild.value?.stage, FluidPageStage.answer);

      live(stageEdit(r'$a1e1', r'$a1', 'photos'));
      expect(manager.pageBuild.value?.stage, FluidPageStage.photos);
      live(stageEdit(r'$a1e2', r'$a1', 'layout'));
      expect(manager.pageBuild.value?.stage, FluidPageStage.layout);

      // Этап чужого обещания панель не трогает.
      live(stageEdit(r'$x1', r'$other', 'failed'));
      expect(manager.pageBuild.value?.stage, FluidPageStage.layout);

      // Повторная доставка обещания не переоткрывает закрытую панель.
      manager.close(kFluidPageAppId);
      live(promise(r'$a1'));
      expect(manager.hasApps, isFalse);
    });

    test('мультикейс отказа: не side / история / не бот / чужая комната', () {
      // AC:RL-liza-liquid-page/32
      live(promise(r'$b1'), side: false);
      live(promise(r'$b2', ts: openedAt.subtract(const Duration(minutes: 5))));
      live(promise(r'$b3', sender: '@human:example.invalid'));
      live(promise(r'$b4', sender: client.userID!));
      final other = Room(id: '!other:example.invalid', client: client);
      final foreign = Event.fromJson({
        ...promise(r'$b5').toJson(),
        'room_id': other.id,
      }, other);
      live(foreign);
      expect(manager.hasApps, isFalse);
    });

    test('готовая страница встаёт на место панели «собираю»', () {
      // AC:RL-liza-liquid-page/33
      live(promise(r'$c1'));
      final p = page(r'$cp1', pending: r'$c1');
      expect(
        shouldAutoOpenLiveFluidPage(
          event: p,
          roomId: room.id,
          openedAt: openedAt,
          sideLayout: true,
          isBotOrAiUser: isBot,
        ),
        isTrue,
      );
      manager.openPage(p, title: 'Цвета');
      expect(manager.apps.length, 1);
      expect(manager.activeApp?.pageEvent?.eventId, r'$cp1');
      expect(manager.showsPending(r'$c1'), isFalse);
    });

    test('закрыл панель «собираю» — страница этого обещания сама не лезет', () {
      // AC:RL-liza-liquid-page/34
      live(promise(r'$d1'));
      manager.close(kFluidPageAppId);
      expect(manager.isPendingDismissed(r'$d1'), isTrue);
      bool decide(Event e) => shouldAutoOpenLiveFluidPage(
        event: e,
        roomId: room.id,
        openedAt: openedAt,
        sideLayout: true,
        isBotOrAiUser: isBot,
      );
      expect(decide(page(r'$dp1', pending: r'$d1')), isFalse);
      // Страница другого обещания и без привязки — открываются.
      expect(decide(page(r'$dp2', pending: r'$other')), isTrue);
      expect(decide(page(r'$dp3')), isTrue);
    });
  });

  Widget app(Widget child) => MaterialApp(
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: const Locale('ru'),
    home: Scaffold(body: child),
  );

  /// Делегаты L10n грузятся настоящим async — до них дерево пустое;
  /// pumpAndSettle не годится: макет страницы пульсирует бесконечно.
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
    testWidgets('панель: этапы, таймер, макет; сбой — сообщение', (
      tester,
    ) async {
      // AC:RL-liza-liquid-page/35
      final started = DateTime.now().subtract(const Duration(seconds: 42));
      manager.openPendingPage(
        room,
        FluidPagePending(
          id: r'$w1',
          stage: FluidPageStage.answer,
          started: started,
        ),
        title: 'Собираю',
      );
      await tester.pumpWidget(
        app(const FluidPageBuildingView(pendingId: r'$w1')),
      );
      await settleL10n(tester);
      expect(find.text('Собираю страницу'), findsOneWidget);
      expect(find.byKey(const ValueKey('fluid-page-skeleton')), findsOneWidget);
      expect(stepRunning('answer'), findsOneWidget);
      final elapsed = tester.widget<Text>(
        find.byKey(const ValueKey('fluid-page-build-elapsed')),
      );
      expect(elapsed.data, anyOf('0:42', '0:43'));

      for (final (stage, name) in [
        (FluidPageStage.photos, 'photos'),
        (FluidPageStage.layout, 'layout'),
      ]) {
        manager.updatePending(
          FluidPagePending(id: r'$w1', stage: stage, started: started),
        );
        await tester.pump();
        expect(stepRunning(name), findsOneWidget);
        expect(
          find.byKey(const ValueKey('fluid-page-step-running')),
          findsOneWidget,
        );
      }

      // Таймер идёт сам: прошло 2 с настоящего времени + тики Timer.periodic.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('fluid-page-build-elapsed')),
            )
            .data,
        anyOf('0:44', '0:45'),
      );

      manager.updatePending(
        FluidPagePending(
          id: r'$w1',
          stage: FluidPageStage.failed,
          started: started,
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('fluid-page-build-failed')),
        findsOneWidget,
      );
      expect(
        find.text('Страницу собрать не получилось — ответ в чате'),
        findsOneWidget,
      );
    });

    testWidgets('карточка в ленте: ∀ этапов — свой вид, тап только в работе', (
      tester,
    ) async {
      // AC:RL-liza-liquid-page/36
      var taps = 0;
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
              onTap: () => taps++,
            ),
          ),
        );
        await settleL10n(tester);
      }

      for (final stage in kFluidPageSteps) {
        await show(stage);
        expect(stepRunning(stage.name), findsOneWidget);
        expect(find.text('Собираю страницу'), findsOneWidget);
        await tester.tap(
          find.byKey(ValueKey('fluid-page-progress-${stage.name}')),
        );
      }
      expect(taps, kFluidPageSteps.length);

      await show(FluidPageStage.done);
      expect(find.text('Страница готова'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fluid-page-progress-done')));

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
      expect(taps, kFluidPageSteps.length);
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
