// ignore_for_file: depend_on_referenced_packages
// ledger:RL-bot-buttons-tap-answer
//
// Кнопки бота (bot-api-compat-fixes, D10): тап не блокирует остальные кнопки,
// ожидание ограничено ответом бота или 15 с, сбой отправки честно показан, ответ
// бота (answerCallbackQuery → to-device com.liza.bot.callback_answer) виден
// только нажавшему. Реальный виджет XlButtonsContent + реальный Client с
// подменённым HTTP-транспортом.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show Request, Response;
import 'package:matrix/matrix.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/xl_buttons_content.dart';
import 'package:liza/pages/chat/external_link_web_view.dart';
import 'package:liza/utils/bot_callback.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/test_client.dart';

const _bot = '@bot_father:liza.local';
const _roomId = '!1234:fakeServer.notExisting';

/// Транспорт с управляемым PUT нажатия (и, по желанию, «зависшей» отправкой
/// обычного сообщения — как заливка видео в очереди комнаты).
class _Api extends FakeMatrixApi {
  final taps = <Map<String, Object?>>[];
  int tapStatus = 200;
  Completer<void>? hangTap;
  Completer<void>? hangMessage;
  int _n = 0;

  @override
  FutureOr<Response> mockIntercept(Request request) async {
    final path = request.url.path;
    if (request.method == 'PUT' &&
        path.contains('/send/$botCallbackEventType/')) {
      taps.add(jsonDecode(request.body) as Map<String, Object?>);
      if (hangTap != null) await hangTap!.future;
      if (tapStatus != 200) {
        return Response(
          jsonEncode({'errcode': 'M_UNKNOWN', 'error': 'boom'}),
          tapStatus,
        );
      }
      return Response(jsonEncode({'event_id': '\$tap${_n++}'}), 200);
    }
    if (request.method == 'PUT' &&
        path.contains('/send/m.room.message/') &&
        hangMessage != null) {
      await hangMessage!.future;
    }
    return super.mockIntercept(request);
  }
}

class _FakeInAppWebViewPlatform extends InAppWebViewPlatform
    with MockPlatformInterfaceMixin {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _FakeInAppWebViewWidget(params);
}

class _FakeInAppWebViewWidget extends PlatformInAppWebViewWidget
    with MockPlatformInterfaceMixin {
  _FakeInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _buttons = [
  {'index': '1', 'title': 'Пицца', 'callback': true},
  {'index': '2', 'title': 'Суши', 'callback': true},
  {'index': '3', 'title': 'Сайт', 'url': 'https://example.org/menu'},
];

void main() {
  setUp(() {
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
  });

  Future<(Client, Room, _Api)> setup(WidgetTester tester) async {
    final api = _Api();
    late final Client client;
    await tester.runAsync(() async {
      client = await prepareTestClient(loggedIn: true, httpClient: api);
    });
    addTearDown(client.dispose);
    final room = Room(id: _roomId, client: client);
    client.rooms.add(room);
    return (client, room, api);
  }

  Future<void> show(WidgetTester tester, Room room) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Provider<MatrixState>.value(
          value: MatrixState(),
          child: Scaffold(
            body: XlButtonsContent(
              event: Event(
                type: EventTypes.Message,
                content: {
                  'msgtype': 'm.text',
                  'body': 'Что заказать?',
                  'com.liza.xl_buttons': _buttons,
                  'com.liza.xl_text_html': 'Что заказать?',
                },
                eventId: '\$card',
                senderId: _bot,
                originServerTs: DateTime.now(),
                room: room,
              ),
              textColor: const Color(0xFF000000),
              linkColor: const Color(0xFF0000FF),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  Finder button(String title) => find.widgetWithText(OutlinedButton, title);

  Finder spinnerIn(String title) => find.descendant(
    of: button(title),
    matching: find.byType(CircularProgressIndicator),
  );

  Finder checkIn(String title) =>
      find.descendant(of: button(title), matching: find.byIcon(Icons.check));

  // Клиент ходит в БД (sqflite ffi, реальный isolate) по пути отправки: даём
  // реальному циклу событий прокрутиться, а фейковые таймеры (15 с, 10 с)
  // двигаем только pump-ом.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, String title) async {
    await tester.tap(button(title));
    await settle(tester);
  }

  void answer(
    Client client,
    Map<String, Object?> content, {
    String sender = _bot,
  }) => client.onToDeviceEvent.add(
    ToDeviceEvent(
      sender: sender,
      type: botCallbackAnswerEventType,
      content: content,
    ),
  );

  Map<String, Object?> base(String index) => {
    'room_id': _roomId,
    'event_id': '\$card',
    'index': index,
  };

  testWidgets('тап по одной кнопке не блокирует другие (включая url), у каждой '
      'свой спиннер; повторный тап по ждущей игнорируется', (tester) async {
    // AC:RL-bot-buttons-tap-answer/1
    final (_, room, api) = await setup(tester);
    await show(tester, room);

    await tap(tester, 'Пицца');
    expect(spinnerIn('Пицца'), findsOneWidget);
    for (final t in ['Суши', 'Сайт']) {
      expect(
        tester.widget<OutlinedButton>(button(t)).onPressed,
        isNotNull,
        reason: '«$t» не должна блокироваться, пока ждёт «Пицца»',
      );
    }

    await tap(tester, 'Суши');
    expect(spinnerIn('Пицца'), findsOneWidget);
    expect(spinnerIn('Суши'), findsOneWidget);
    await tap(tester, 'Пицца');
    expect(api.taps.map((t) => t['index']), ['1', '2']);

    // tap_id — 16 случайных байт в hex, у каждого нажатия свой.
    final ids = api.taps.map((t) => t['tap_id']! as String).toList();
    expect(ids.every(RegExp(r'^[0-9a-f]{32}$').hasMatch), isTrue);
    expect(ids.toSet(), hasLength(2));
    expect(api.taps.first['m.relates_to'], {
      'rel_type': botCallbackEventType,
      'event_id': '\$card',
    });
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('бот не ответил → спиннер снимается через 15 с молча, '
      'нажатая кнопка отмечена', (tester) async {
    // AC:RL-bot-buttons-tap-answer/2
    final (_, room, _) = await setup(tester);
    await show(tester, room);

    await tap(tester, 'Пицца');
    await tester.pump(const Duration(seconds: 14));
    expect(spinnerIn('Пицца'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1, milliseconds: 100));
    expect(spinnerIn('Пицца'), findsNothing);
    expect(checkIn('Пицца'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('нажатие уходит, пока в комнате висит отправка другого события '
      '(очередь комнаты не задерживает тап)', (tester) async {
    // AC:RL-bot-buttons-tap-answer/3
    final (_, room, api) = await setup(tester);
    api.hangMessage = Completer<void>();
    await show(tester, room);

    // Отправка обычного события висит на сервере (как заливка видео) — она в
    // реальной зоне, чтобы не зависеть от фейкового времени.
    late final Future<String?> upload;
    await tester.runAsync(() async {
      upload = room.sendTextEvent('видео ещё заливается');
      for (
        var i = 0;
        i < 300 &&
            FakeMatrixApi.calledEndpoints.keys.every(
              (k) => !k.contains('/send/m.room.message/'),
            );
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(api.hangMessage!.isCompleted, isFalse);
    await tap(tester, 'Пицца');
    expect(api.taps, hasLength(1));
    expect(spinnerIn('Пицца'), findsOneWidget);
    await tester.runAsync(() async {
      api.hangMessage!.complete();
      await upload;
    });
    await tester.pump(const Duration(seconds: 16));
  });

  for (final (name, configure) in <(String, void Function(_Api))>[
    ('ответ 5xx', (api) => api.tapStatus = 500),
    ('нет ответа 10 с (таймаут)', (api) => api.hangTap = Completer<void>()),
  ]) {
    testWidgets('сбой отправки ($name) → ошибка пользователю, галочки нет', (
      tester,
    ) async {
      // AC:RL-bot-buttons-tap-answer/4
      final (_, room, api) = await setup(tester);
      configure(api);
      await show(tester, room);

      await tap(tester, 'Пицца');
      await tester.pump(const Duration(seconds: 10, milliseconds: 100));
      await tester.pump();
      expect(
        find.text('Не удалось отправить нажатие кнопки. Попробуйте ещё раз.'),
        findsOneWidget,
      );
      expect(checkIn('Пицца'), findsNothing);
      expect(spinnerIn('Пицца'), findsNothing);
      api.hangTap?.complete();
      await tester.pump(const Duration(seconds: 16));
    });
  }

  testWidgets('ответ text → всплывающая плашка, спиннер снят', (tester) async {
    // AC:RL-bot-buttons-tap-answer/5
    final (client, room, api) = await setup(tester);
    await show(tester, room);

    await tap(tester, 'Пицца');
    answer(client, {
      ...base('1'),
      'tap_id': api.taps.single['tap_id'],
      'text': 'Готово',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.widgetWithText(SnackBar, 'Готово'), findsOneWidget);
    expect(spinnerIn('Пицца'), findsNothing);
    expect(checkIn('Пицца'), findsOneWidget);
    expect(BotCallbackAnswers.of(client).pendingCount, 0);
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('ответ show_alert → диалог с текстом и OK', (tester) async {
    // AC:RL-bot-buttons-tap-answer/6
    final (client, room, api) = await setup(tester);
    await show(tester, room);

    await tap(tester, 'Суши');
    answer(client, {
      ...base('2'),
      'tap_id': api.taps.single['tap_id'],
      'text': 'Суши закончились',
      'show_alert': true,
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Суши закончились'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('Ок'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Суши закончились'), findsNothing);
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('ответ url → открывается как url-кнопка (встроенный webview)', (
    tester,
  ) async {
    // AC:RL-bot-buttons-tap-answer/7
    final (client, room, api) = await setup(tester);
    await show(tester, room);

    await tap(tester, 'Пицца');
    answer(client, {
      ...base('1'),
      'tap_id': api.taps.single['tap_id'],
      'url': 'https://example.org/game',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ExternalLinkWebView), findsOneWidget);
  });

  testWidgets('ответ без tap_id (сервер не знал id) → по (комната, событие, '
      'номер) своего ждущего нажатия', (tester) async {
    // AC:RL-bot-buttons-tap-answer/5
    final (client, room, _) = await setup(tester);
    await show(tester, room);

    await tap(tester, 'Пицца');
    answer(client, {...base('1'), 'text': 'Принято'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.widgetWithText(SnackBar, 'Принято'), findsOneWidget);
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('игнор ∀ {чужой отправитель, чужой tap_id (другое устройство), '
      'нет ждущего нажатия}', (tester) async {
    // AC:RL-bot-buttons-tap-answer/8
    final (client, room, api) = await setup(tester);
    await show(tester, room);

    answer(client, {...base('1'), 'text': 'без нажатия'});
    await tap(tester, 'Пицца');
    final tapId = api.taps.single['tap_id'];
    answer(client, {
      ...base('1'),
      'tap_id': tapId,
      'text': 'подделка',
    }, sender: '@evil:liza.local');
    answer(client, {
      ...base('1'),
      'tap_id': 'f' * 32,
      'text': 'чужое устройство',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SnackBar), findsNothing);
    expect(spinnerIn('Пицца'), findsOneWidget);
    expect(BotCallbackAnswers.of(client).pendingCount, 1);

    await tester.pump(const Duration(seconds: 16));
    expect(BotCallbackAnswers.of(client).pendingCount, 0);
  });

  testWidgets('виджет убран до ответа → ждущее нажатие и таймер сняты', (
    tester,
  ) async {
    // AC:RL-bot-buttons-tap-answer/2
    final (client, room, _) = await setup(tester);
    await show(tester, room);

    await tap(tester, 'Пицца');
    expect(BotCallbackAnswers.of(client).pendingCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(BotCallbackAnswers.of(client).pendingCount, 0);
    // Без утечки таймера: тест-биндинг упал бы на «A Timer is still pending».
  });
}
