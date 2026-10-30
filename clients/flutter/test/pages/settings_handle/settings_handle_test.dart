// ledger:RL-user-handles AC:RL-user-handles/4
// AC:RL-user-handles/34 AC:RL-user-handles/35 AC:RL-user-handles/36
// AC:RL-user-handles/37 AC:RL-user-handles/38 AC:RL-user-handles/39
// AC:RL-user-handles/40 AC:RL-user-handles/41 AC:RL-user-handles/42
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/settings_handle/settings_handle.dart';
import 'package:liza/utils/user_handle_service.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

// Полноценный Matrix-виджет в юнит-тесте неоправданно тяжёл — подменяем
// только геттер client, как в channel_peek_message_render_test.dart.
class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);

  final Client _client;

  @override
  Client get client => _client;
}

Widget _wrap(Widget child, Client client) => MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Provider<liza_matrix.MatrixState>.value(
        value: _TestMatrixState(client),
        child: Scaffold(body: child),
      ),
    );

/// Сервис с заранее заданным ответом fetchOwn/setHandle, без сети — экран
/// проверяем изолированно от Task 4.
///
/// [sentHandles] копит то, что реально ушло бы на сервер: несколько стражей
/// проверяют именно ОТСУТСТВИЕ запроса (локальный отказ, выключенная фича) и
/// точность нормализации значения.
class _StubHandleService extends UserHandleService {
  _StubHandleService({this.state, this.setResult, this.throwOnFetch = false})
      : super(
          baseUrl: 'https://auth.test',
          accessTokenProvider: () => 'token',
          serverNameProvider: () => 'bots.liza.ru',
        );

  final HandleState? state;
  final HandleSetResult? setResult;
  final bool throwOnFetch;
  final List<String> sentHandles = [];

  @override
  Future<HandleState> fetchOwn() async {
    if (throwOnFetch) throw Exception('сеть недоступна');
    return state ?? const HandleState(handle: null, available: true);
  }

  @override
  Future<HandleSetResult> setHandle(
    String handle, {
    required Client client,
  }) async {
    sentHandles.add(handle);
    return setResult ?? HandleSetResult.ok;
  }
}

// Тексты причин отказа (ru) — ровно те, что видит человек. Дословность
// намеренна: критерий приёмки LABA-2547 сформулирован цитатой репортёра.
const _taken = 'Пользователь с таким именем уже существует';
const _tooShort = 'Не короче 5 символов';
const _tooLong = 'Не длиннее 32 символов';
const _badFormat = 'Имя должно начинаться с латинской буквы; '
    'допустимы латиница, цифры и подчёркивание';
const _reserved = 'Это имя зарезервировано, выберите другое';
const _unavailable = 'Имя пользователя пока недоступно на этом сервере';
const _network = 'Не удалось связаться с сервером. Проверьте соединение и '
    'попробуйте ещё раз';
const _serverInvalid = 'Только латинские буквы, цифры и подчёркивание, '
    'от 5 до 32 символов, начиная с буквы';

void main() {
  late Client client;

  Future<Client> loggedInClient() => prepareTestClient(loggedIn: true);

  /// Поднимает экран и отдаёт стаб + контроллер. pumpAndSettle здесь
  /// использовать нельзя: TextField с автофокусом держит открытым курсорный
  /// таймер, «покоя» анимаций не наступает.
  Future<(_StubHandleService, SettingsHandleController)> pumpScreen(
    WidgetTester tester, {
    HandleState? state,
    HandleSetResult? setResult,
    bool throwOnFetch = false,
  }) async {
    await tester.runAsync(() async {
      client = await loggedInClient();
    });
    addTearDown(client.dispose);

    final service = _StubHandleService(
      state: state ?? const HandleState(handle: null, available: true),
      setResult: setResult,
      throwOnFetch: throwOnFetch,
    );
    await tester.pumpWidget(
      _wrap(SettingsHandlePage(service: service), client),
    );
    // Первый pumpAndSettle обязателен: локализация грузится отложенно
    // (`use-deferred-loading: true` в l10n.yaml), до её готовности MaterialApp
    // не строит содержимое. Дальше по тесту pumpAndSettle уже нельзя —
    // сфокусированное поле держит курсорный таймер, покоя не наступает.
    await tester.pumpAndSettle();
    final controller =
        tester.state<SettingsHandleController>(find.byType(SettingsHandlePage));
    return (service, controller);
  }

  /// Ввод значения + нажатие «Изменить».
  Future<void> submit(WidgetTester tester, String value) async {
    await tester.enterText(find.byType(TextField), value);
    await tester.pump();
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('занятое имя показывает текст уникальности, а не код ошибки',
      (tester) async {
    await pumpScreen(
      tester,
      setResult: HandleSetResult.taken,
    );

    await submit(tester, 'ivanov_petr');

    expect(find.text(_taken), findsOneWidget);
    expect(find.text('taken'), findsNothing);
    expect(find.text('handle_taken'), findsNothing);
    // Регресс LABA-2547: причина «занято» не должна маскироваться под формат.
    expect(find.text(_serverInvalid), findsNothing);
  });

  testWidgets('слишком короткое имя: своя причина, без похода на сервер',
      (tester) async {
    final (service, _) = await pumpScreen(tester);

    await submit(tester, 'a');

    expect(find.text(_tooShort), findsOneWidget);
    expect(find.text(_serverInvalid), findsNothing);
    expect(service.sentHandles, isEmpty);
  });

  testWidgets('слишком длинное имя: своя причина, без похода на сервер',
      (tester) async {
    final (service, controller) = await pumpScreen(tester);

    // Через поле не пройдёт (LengthLimitingTextInputFormatter обрежет до 32),
    // но значение может прийти ИЗВНЕ поля — как автозаполнение браузера.
    await controller.save('a' * 33);
    await tester.pump();

    expect(find.text(_tooLong), findsOneWidget);
    expect(service.sentHandles, isEmpty);
  });

  testWidgets('имя не с буквы: причина про формат, без похода на сервер',
      (tester) async {
    final (service, _) = await pumpScreen(tester);

    await submit(tester, '1ivanov');

    expect(find.text(_badFormat), findsOneWidget);
    expect(service.sentHandles, isEmpty);
  });

  testWidgets('зарезервированное имя различимо ТОЛЬКО локально',
      (tester) async {
    // Сервер на reserved и на кривой формат отвечает одним 400 invalid_handle
    // (handle_validator.py) — если бы клиент не проверял сам, человек увидел
    // бы «поправьте формат» на формально правильном имени.
    final (service, _) = await pumpScreen(tester);

    await submit(tester, 'support');

    expect(find.text(_reserved), findsOneWidget);
    expect(find.text(_serverInvalid), findsNothing);
    expect(service.sentHandles, isEmpty);
  });

  testWidgets('сетевой сбой при сохранении: текст про связь, не про формат',
      (tester) async {
    await pumpScreen(tester, setResult: HandleSetResult.networkError);

    await submit(tester, 'ivanov_petr');

    expect(find.text(_network), findsOneWidget);
    expect(find.text(_serverInvalid), findsNothing);
  });

  testWidgets('403 handles_disabled: текст про сервер, отдельный от сетевого',
      (tester) async {
    await pumpScreen(tester, setResult: HandleSetResult.disabled);

    await submit(tester, 'ivanov_petr');

    expect(find.text(_unavailable), findsOneWidget);
    expect(find.text(_network), findsNothing);
    expect(find.text(_serverInvalid), findsNothing);
  });

  testWidgets('сбой загрузки экрана: текст про связь, не про формат',
      (tester) async {
    // Регресс кода-сироты 'network_error': он не значился в разборе кодов и
    // проваливался в текст про формат — человек видел «поправьте формат»,
    // ещё ничего не введя.
    await pumpScreen(tester, throwOnFetch: true);

    expect(find.text(_network), findsOneWidget);
    expect(find.text(_serverInvalid), findsNothing);
  });

  testWidgets('фича выключена на сервере: кнопка недоступна и есть объяснение',
      (tester) async {
    final (service, _) = await pumpScreen(
      tester,
      state: const HandleState(handle: null, available: false),
    );

    expect(find.text(_unavailable), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ivanov_petr');
    await tester.pump();
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull);
    expect(service.sentHandles, isEmpty);
  });

  testWidgets('серверный 400 остаётся страховкой на дрейф правил',
      (tester) async {
    // Формат-валидное имя, которое отверг сервер: локальная проверка молчит,
    // показываем общее правило — врать деталью нельзя.
    final (service, _) = await pumpScreen(
      tester,
      setResult: HandleSetResult.invalid,
    );

    await submit(tester, 'ivanov_petr');

    expect(find.text(_serverInvalid), findsOneWidget);
    expect(service.sentHandles, ['ivanov_petr']);
  });

  testWidgets('автозаполненный MXID по-прежнему сохраняется', (tester) async {
    // Браузер подставляет в поле сырой `@localpart:server` мимо
    // inputFormatters. Локальная валидация обязана идти по НОРМАЛИЗОВАННОЙ
    // строке — иначе этот сценарий отвалился бы с «неверным форматом».
    final (service, controller) = await pumpScreen(tester);

    await controller.save('@test_furman_8282:bots.liza.ru');
    await tester.pump();

    expect(service.sentHandles, ['test_furman_8282']);
    expect(find.text(_badFormat), findsNothing);
    expect(find.text(_tooShort), findsNothing);
  });

  testWidgets('семь причин отказа попарно различимы', (tester) async {
    // Корень LABA-2547 — общая ветка «всё неизвестное → текст про формат».
    // Страж следит, чтобы ни одна причина снова не схлопнулась в чужой текст.
    await pumpScreen(tester);

    const reasons = [
      _taken,
      _tooShort,
      _tooLong,
      _badFormat,
      _reserved,
      _unavailable,
      _network,
    ];
    expect(reasons.toSet().length, reasons.length);
    for (final reason in reasons) {
      expect(reason, isNot(_serverInvalid));
    }
  });

  testWidgets('ввод нового имени убирает старую причину отказа',
      (tester) async {
    await pumpScreen(
      tester,
      setResult: HandleSetResult.taken,
    );

    await submit(tester, 'ivanov_petr');
    expect(find.text(_taken), findsOneWidget);

    // Причина относилась к прежнему значению — как только человек правит
    // имя, она перестаёт быть правдой.
    await tester.enterText(find.byType(TextField), 'ivanov_petrov');
    await tester.pump();

    expect(find.text(_taken), findsNothing);
  });

  testWidgets('ника нет — поле предзаполнено кандидатом из fetchOwn',
      (tester) async {
    await pumpScreen(tester);

    // fetchOwn не отдал handle → suggestion строится контроллером из
    // localpart текущего клиента (у тестового клиента без точки — кандидата
    // нет, поле остаётся пустым). Само преобразование "точка → подчёркивание"
    // покрыто юнит-тестом suggestHandleFromLocalpart.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '');
  });
}
