import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/demo_auth/demo_auth_service.dart';
import 'package:liza/pages/demo_auth/sms_code_source.dart';
import 'package:liza/pages/demo_auth/steps/demo_email_code_step.dart';
import 'package:liza/pages/demo_auth/steps/demo_select_server_step.dart';
import 'package:liza/pages/demo_auth/steps/demo_sms_step.dart';
import 'package:liza/pages/demo_auth/steps/demo_starting_step.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/matrix.dart';

/// Шаги демо-флоу. Телефон вводится на первом экране (HomeserverPicker),
/// никнейм генерирует сервер, адрес почты вводится в настройках —
/// здесь остаётся только подтверждение.
///
/// `starting` — ожидание ответа `/phone/start`. Отдельный шаг, а не флаг:
/// канал доставки выбирает СЕРВЕР, и до его ответа неизвестно, рисовать
/// экран СМС или письма. Раньше начальным значением стоял `sms`, и первый
/// кадр всегда показывал экран СМС — при доставке письмом он тут же
/// перерисовывался в «Код из письма», и человек видел мигание.
enum DemoAuthStep { starting, sms, emailCode, selectServer }

/// Канал доставки кода первого шага.
///
/// Строк `'phone'`/`'email'` в коде экрана больше нет: канал приходит от
/// сервера, уходит обратно в `/phone/start` и выбирается человеком в меню
/// «Другой способ» — три места, которые обязаны согласоваться. Третий способ
/// (мессенджер, звонок) добавляется сюда одним значением.
enum DemoAuthChannel {
  phone,
  email,

  /// Вход App Store review: вместо кода — пароль. В меню «Другой способ» не
  /// предлагается (см. [DemoAuthFlowController.availableChannels]): его
  /// выбирает только сервер по номеру.
  password;

  /// Значение, которое понимает auth-proxy.
  ///
  /// Обратного разбора здесь нет намеренно: ответ сервера разбирает сам
  /// [DemoAuthStartResult] (`isEmailChannel`) — это граница с сетью, и
  /// дублировать её маппингом в UI-слое незачем.
  String get wireName => switch (this) {
    DemoAuthChannel.phone => 'phone',
    DemoAuthChannel.email => 'email',
    DemoAuthChannel.password => 'password',
  };
}

/// Отличает актуальный сетевой запрос флоу от ответа, который пришёл позже.
///
/// Переключение канала не отменяет HTTP-запрос в браузере, поэтому отмена
/// здесь логическая: только последний запрос вправе менять шаг и получателя.
class DemoAuthRequestEpoch {
  int _value = 0;

  int begin() => ++_value;

  bool isCurrent(int value) => value == _value;
}

/// Вход по телефону с SMS/email OTP на prod и dev.
///
/// Весь UI остаётся внутри приложения. Локальная сборка использует вход
/// паролем, поэтому маршрут в ней отсутствует.
class DemoAuthFlow extends StatefulWidget {
  const DemoAuthFlow({
    super.key,
    required this.phone,
    this.addMultiAccount = false,
    this.service,
    this.onAuthenticated,
    this.smsCodeSource,
  });

  final String phone;

  /// Флоу открыт из «Добавить аккаунт» уже вошедшим пользователем. Выход из
  /// флоу ведёт обратно на экран добавления: `/home` стоит под
  /// `loggedInRedirect` и выкинул бы в список чатов. Навигацию после входа
  /// ведёт `Matrix.handleLoginStateChange` — он сворачивает стек добавления
  /// и выбирает `/rooms` или `/backup` по роли НОВОГО аккаунта.
  final bool addMultiAccount;

  /// Переопределяется только интеграционным каркасом: в приложении сервис
  /// создаётся по умолчанию и ходит в auth-proxy.
  final DemoAuthService? service;

  /// Точка передачи готового login-token для интеграционного каркаса.
  ///
  /// Обычный путь логинит Matrix-клиент ниже; callback позволяет проверить
  /// auth-proxy flow без живого Matrix-сервера.
  final Future<void> Function(DemoAuthTokens tokens)? onAuthenticated;

  /// Подмена источника кода из СМС — только для тестов (плагин на хосте не
  /// работает). В приложении null: шаг берёт системный источник сам.
  final SmsCodeSource? smsCodeSource;

  @override
  State<DemoAuthFlow> createState() => DemoAuthFlowController();
}

/// Экран «Добавить аккаунт» — туда же возвращает выход из флоу входа по
/// телефону в режиме мультиаккаунта.
const addAccountPath = '/rooms/settings/addaccount';

/// Куда уходит пользователь, покидая флоу входа (назад, истёкшая сессия,
/// пустой номер после перезагрузки web).
String demoAuthExitPath({required bool addMultiAccount}) =>
    addMultiAccount ? addAccountPath : '/home';

class DemoAuthFlowController extends State<DemoAuthFlow> {
  late final DemoAuthService _service;
  final DemoAuthRequestEpoch _requests = DemoAuthRequestEpoch();

  DemoAuthStep step = DemoAuthStep.starting;
  bool isLoading = false;
  String? error;

  /// Код последней ошибки от сервера — по нему шаги решают, показывать ли
  /// вместо текста кнопку выхода в поддержку (тупиковые коды).
  String? errorCode;

  /// Сколько раз сервер отклонил введённый код. Шаг ключует им поле кода:
  /// новое значение пересоздаёт ячейки пустыми (LABA-2528). Иначе отклонённые
  /// цифры оставались, а ввод в заполненную ячейку уходил в ветку вставки.
  int codeRejections = 0;

  /// Ставить ли курсор в первую ячейку после отказа. Только для неверного
  /// кода: при истёкшем или исчерпанном вводить уже нечего, а клавиатура
  /// закрыла бы текст ошибки и кнопку поддержки под полем.
  bool focusCodeAfterReject = false;

  String? _ticket;

  /// Тикет текущей попытки — нужен форме поддержки, чтобы обращение
  /// привязалось к тому же флоу входа.
  String? get ticket => _ticket;
  String phone = '';
  String maskedPhone = '';

  /// Код первого шага ушёл письмом, а не СМС (сервер выбирает письмо, когда
  /// у номера есть аккаунт с настоящей почтой). Влияет на текст экрана.
  bool smsCodeSentByEmail = false;

  /// Сервер ответил каналом `password` (номер App Store review): шаг
  /// рисует поле пароля вместо ячеек кода, без таймера повтора и без
  /// «Другого способа» — повторять и переключать здесь нечего.
  bool passwordLogin = false;

  /// Доставка не состоялась из-за лимита частоты (а не сбоя): текст должен
  /// сказать «подождите», а не «сервис не смог отправить».
  bool deliveryRateLimited = false;

  /// Пояснение от сервиса доставки (англ., без ПДн).
  String deliveryDetail = '';

  /// Код известной ошибки сервиса OTP — из него берётся текст НА ЯЗЫКЕ
  /// ИНТЕРФЕЙСА. Сырой `deliveryDetail` (английский, внутренние термины
  /// сервиса) человеку не показываем.
  String deliveryDetailCode = '';
  String? maskedEmail;
  String? email;
  bool deliveryFailed = false;
  bool isExistingUser = false;
  List<DemoAuthAccount> accounts = const [];

  /// Сколько секунд до разрешённого повтора — по данным СЕРВЕРА. `null`,
  /// пока сервер поле не прислал: тогда шаг считает по своему таймеру.
  int? resendAvailableIn;

  /// Растёт на каждый СЕРВЕРНЫЙ ответ с `resend_available_in`. Шаг
  /// перезапускает отсчёт только по новой эпохе, а не по значению: сравнение
  /// «больше текущего» держало второй 33-минутный таймер после «Отправить ещё
  /// раз» (ответ 60 с не пробивал остаток старого лимита) и перезапускало
  /// отсчёт при любой перерисовке контроллера — неверный код на 0:30 отбрасывал
  /// его к 1:00 (LABA-2526).
  int resendEpoch = 0;

  void _setResendAvailableIn(int? seconds) {
    resendAvailableIn = seconds;
    resendEpoch++;
  }

  /// У человека подтверждены и телефон, и почта — значит есть из чего
  /// выбирать, и кнопка «Другой способ» осмысленна. Считается по ответу
  /// `/phone/verify`; регистрация альтернативы не имеет по определению.
  bool hasAlternativeChannel = false;

  /// Альтернатива доступна и ДО ввода первого кода — если сервер сам увёл
  /// доставку в почту (`channel: email` на `/phone/start`). Такой выбор он
  /// делает только для существующего человека с настоящей почтой, то есть
  /// подтверждены оба канала: телефон — тот, что ввели, почта — та, куда
  /// ушёл код. Без этого кнопка появлялась лишь на ВТОРОМ экране, а на
  /// первом — где человек как раз и застревает, не получив письмо, — её
  /// не было вовсе.
  bool get canSwitchChannel =>
      !passwordLogin && (hasAlternativeChannel || smsCodeSentByEmail);

  /// Канал, которым сейчас доставляется код первого шага.
  DemoAuthChannel get currentChannel => passwordLogin
      ? DemoAuthChannel.password
      : smsCodeSentByEmail
      ? DemoAuthChannel.email
      : DemoAuthChannel.phone;

  /// Способы, которые можно предложить в меню «Другой способ».
  ///
  /// Показываем ВСЕ доступные (включая текущий, помеченный активным): меню
  /// из одного пункта не объясняет, чем человек пользуется сейчас, а список
  /// сразу читается как выбор.
  List<DemoAuthChannel> get availableChannels => const [
    DemoAuthChannel.phone,
    DemoAuthChannel.email,
  ];

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? DemoAuthService();
    phone = widget.phone;
    // Первый экран (HomeserverPicker) только собирает номер — код
    // заказываем здесь, при открытии флоу подтверждения.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startPhone());
  }

  String get _exitPath =>
      demoAuthExitPath(addMultiAccount: widget.addMultiAccount);

  Future<void> _startPhone() async {
    final request = _requests.begin();
    if (!mounted) return;
    if (phone.isEmpty) {
      // Прямой заход на /auth/phone (закладка, F5, ручной URL) —
      // extra пуст. Заказывать код нечем, сервер ответит invalid_phone
      // невнятной ошибкой на экране кода — вместо этого на первый экран.
      context.go(_exitPath);
      return;
    }
    setState(() {
      isLoading = true;
      error = null;
      errorCode = null;
    });
    try {
      final result = await _service.startPhone(phone);
      if (!mounted || !_requests.isCurrent(request)) return;
      setState(() {
        _ticket = result.ticket;
        maskedPhone = result.maskedDestination;
        deliveryFailed = result.deliveryFailed;
        smsCodeSentByEmail = result.isEmailChannel;
        passwordLogin = result.isPasswordChannel;
        deliveryRateLimited = result.isRateLimited;
        deliveryDetail = result.deliveryDetail;
        deliveryDetailCode = result.deliveryDetailCode;
        _setResendAvailableIn(result.resendAvailableIn);
        isLoading = false;
        // Канал известен — только теперь рисуем конкретный экран кода.
        step = DemoAuthStep.sms;
      });
    } on DemoAuthException catch (err) {
      _fail(err, request: request);
    } catch (err, s) {
      _failUnexpected(err, s, request: request);
    }
  }

  /// Повторный заказ кода (кнопка «СМС не пришло»).
  ///
  /// [channel] задаётся кнопкой «Другой способ» — сервер иначе выбирает
  /// канал сам и повтор пришёл бы тем же путём, что и не сработал.
  Future<void> resendSms({String? channel}) async {
    final request = _requests.begin();
    setState(() {
      isLoading = true;
      error = null;
      errorCode = null;
    });
    try {
      final result = await _service.startPhone(
        phone,
        ticket: _ticket,
        channel: channel,
      );
      if (!mounted || !_requests.isCurrent(request)) return;
      setState(() {
        _ticket = result.ticket;
        maskedPhone = result.maskedDestination;
        smsCodeSentByEmail = result.isEmailChannel;
        passwordLogin = result.isPasswordChannel;
        deliveryFailed = result.deliveryFailed;
        deliveryRateLimited = result.isRateLimited;
        deliveryDetail = result.deliveryDetail;
        deliveryDetailCode = result.deliveryDetailCode;
        _setResendAvailableIn(result.resendAvailableIn);
        isLoading = false;
      });
    } on DemoAuthException catch (err) {
      _fail(err, request: request);
    } catch (err, s) {
      _failUnexpected(err, s, request: request);
    }
  }

  /// «Другой способ»: заказать код по ВЫБРАННОМУ в меню каналу.
  ///
  /// Со второго экрана (код письма) возвращаемся на первый: код первого
  /// шага заказывает `/phone/start`, и именно он выбирает канал. Оставить
  /// человека на экране письма, отправив СМС, значило бы врать заголовком.
  ///
  /// Выбор текущего канала — не «переключение», а повторная отправка тем же
  /// путём, который уже не сработал; такой пункт меню просто ничего не
  /// делает (повтор человек заказывает кнопкой «Отправить ещё раз»).
  Future<void> switchChannel(DemoAuthChannel channel) async {
    if (channel == currentChannel && step == DemoAuthStep.sms) return;
    setState(() => step = DemoAuthStep.sms);
    await resendSms(channel: channel.wireName);
  }

  /// Шаг 2: проверка кода из СМС.
  Future<void> submitSmsCode(String code) async {
    final request = _requests.begin();
    setState(() {
      isLoading = true;
      error = null;
      errorCode = null;
    });
    try {
      final result = await _service.verifyPhone(ticket: _ticket!, code: code);
      if (!mounted || !_requests.isCurrent(request)) return;
      setState(() {
        isExistingUser = result.isExistingUser;
        maskedEmail = result.maskedEmail;
        // Альтернативный канал есть только у входа (не регистрации) и только
        // когда подтверждены оба адреса. Явных `email_verified`/`phone_verified`
        // сервер пока не отдаёт — до тех пор считаем по косвенным признакам:
        // телефон только что подтверждён кодом, почта известна серверу.
        hasAlternativeChannel =
            result.isExistingUser &&
            (result.emailVerified ??
                (result.maskedEmail?.isNotEmpty ?? false)) &&
            (result.phoneVerified ?? true);
        deliveryFailed = false;
        error = null;
        errorCode = null;
      });
      // Успешно выбранный способ уже подтверждает вход. Не заказываем
      // дополнительный email-код: особенно важно после email → SMS.
      await _finish(request: request);
    } on DemoAuthException catch (err) {
      // Сюда доходит только отказ verify: `_finish` свои ошибки ловит сам.
      // Это граница очистки — после успешного verify код уже потрачен, и
      // повторный ввод того же кода дал бы «неверный код».
      _fail(err, request: request, rejectCode: true);
    } catch (err, s) {
      _failUnexpected(err, s, request: request);
    }
  }

  /// Шаг 3: код из письма.
  Future<void> submitEmailCode(String code) async {
    final request = _requests.begin();
    setState(() {
      isLoading = true;
      error = null;
      errorCode = null;
    });
    try {
      await _service.verifyEmail(ticket: _ticket!, code: code);
      if (!mounted || !_requests.isCurrent(request)) return;
      await _finish(request: request);
    } on DemoAuthException catch (err) {
      _fail(err, request: request);
    } catch (err, s) {
      _failUnexpected(err, s, request: request);
    }
  }

  /// Повторная отправка кода на почту.
  ///
  /// Пустой адрес — не ошибка: на этом шаге почту знает сервер по тикету,
  /// клиенту она целиком не показывается. Прежняя проверка `email == null`
  /// делала кнопку повтора мёртвой — поле `email` здесь никогда не
  /// присваивалось (экрана ввода почты во флоу больше нет).
  Future<void> resendEmailCode() async {
    final request = _requests.begin();
    setState(() {
      isLoading = true;
      error = null;
      errorCode = null;
    });
    try {
      final result = await _service.sendEmailCode(
        ticket: _ticket!,
        email: email ?? '',
      );
      if (!mounted || !_requests.isCurrent(request)) return;
      setState(() {
        _setResendAvailableIn(result.resendAvailableIn);
        isLoading = false;
      });
    } on DemoAuthException catch (err) {
      _fail(err, request: request);
    } catch (err, s) {
      _failUnexpected(err, s, request: request);
    }
  }

  /// Пользователь выбрал инстанс из списка.
  Future<void> selectServer(String serverName) async {
    final request = _requests.begin();
    setState(() {
      isLoading = true;
      error = null;
      errorCode = null;
    });
    await _finish(serverName: serverName, request: request);
  }

  Future<void> _finish({String? serverName, required int request}) async {
    try {
      final result = await _service.complete(
        ticket: _ticket!,
        serverName: serverName,
      );

      if (result.needsServerChoice) {
        if (!mounted || !_requests.isCurrent(request)) return;
        setState(() {
          accounts = result.accounts;
          step = DemoAuthStep.selectServer;
          isLoading = false;
        });
        return;
      }

      final tokens = result.tokens!;
      if (!mounted || !_requests.isCurrent(request)) return;
      final onAuthenticated = widget.onAuthenticated;
      if (onAuthenticated != null) {
        await onAuthenticated(tokens);
        return;
      }
      final client = await Matrix.of(context).getLoginClient();
      if (!mounted || !_requests.isCurrent(request)) return;
      await client.checkHomeserver(Uri.https(tokens.serverName, ''));
      if (!mounted || !_requests.isCurrent(request)) return;
      await client.login(
        LoginType.mLoginToken,
        token: tokens.loginToken,
        // client_guard отклоняет логин без префикса «Liza» в имени
        // устройства — без этого сервер вернёт M_FORBIDDEN.
        initialDeviceDisplayName: PlatformInfos.clientName,
      );
      if (!mounted || !_requests.isCurrent(request)) return;
      // Второй аккаунт: свой go('/rooms') обогнал бы свёртку стека в
      // handleLoginStateChange (она срабатывает, только пока путь содержит
      // /settings/addaccount) — developer терял бы /backup.
      if (widget.addMultiAccount) return;
      context.go('/rooms');
    } on DemoAuthException catch (err) {
      _fail(err, request: request);
    } catch (err, s) {
      _failUnexpected(err, s, request: request);
    }
  }

  void back() {
    switch (step) {
      case DemoAuthStep.starting:
        context.go(_exitPath);
        return;
      case DemoAuthStep.sms:
        context.go(_exitPath);
        return;
      case DemoAuthStep.emailCode:
        // Шага почты больше нет — возвращаться некуда.
        context.go(_exitPath);
        return;
      case DemoAuthStep.selectServer:
        context.go(_exitPath);
        return;
    }
  }

  void _fail(
    DemoAuthException err, {
    required int request,
    bool rejectCode = false,
  }) {
    if (!mounted || !_requests.isCurrent(request)) return;
    if (err.code == 'ticket_expired') {
      // Экрана повторного ввода телефона в этом флоу больше нет —
      // сессия истекла, начинать заново можно только с первого экрана.
      context.go(_exitPath);
      return;
    }
    setState(() {
      isLoading = false;
      // Шаг НЕ переключаем: ошибку первого запроса показывает сам экран
      // ожидания (DemoAuthStartingStep умеет её рисовать). Раньше здесь
      // стоял перевод на шаг кода — и человек попадал на экран ввода кода,
      // который ему не отправляли: `deliveryFailed` там остаётся false, а
      // `maskedPhone` пуст, поэтому заголовок читался как «Мы отправили СМС
      // на номер .». Так выглядели ВСЕ отказы `/phone/start` — неверный
      // номер, лимит частоты, сбой провайдера, обрыв сети (LABA-2531).
      error = _messageFor(err.code);
      errorCode = err.code;
      if (rejectCode) {
        codeRejections++;
        focusCodeAfterReject = err.code == 'invalid_code';
      }
      // Сервер прислал, сколько ждать — таймер шага пойдёт от него.
      // Ноль пропускаем: часовой потолок провайдера приходит с
      // `resend_available_in: 0`, и он обнулил бы работающий отсчёт.
      final retryAfter = err.resendAvailableIn;
      if (retryAfter != null && retryAfter > 0) {
        _setResendAvailableIn(retryAfter);
      }
    });
  }

  /// Сбой вне контракта сервера: `TypeError` разбора ответа, `_ticket!` без
  /// тикета, отказ Matrix-логина. Мимо `on DemoAuthException` такой сбой
  /// оставлял `isLoading` навсегда, а на шаге ожидания спиннер крутится, пока
  /// нет `error` — вечная загрузка (LABA-2529). Идём через [_fail], чтобы
  /// поздний сбой устаревшего запроса отсекла эпоха.
  void _failUnexpected(Object err, StackTrace stack, {required int request}) {
    Logs().w('demo-auth: неожиданный сбой (${err.runtimeType})', err, stack);
    _fail(const DemoAuthException('internal_error'), request: request);
  }

  String _messageFor(String code) => demoAuthErrorMessage(
    code,
    L10n.of(context),
    passwordChannel: passwordLogin,
  );

  @override
  Widget build(BuildContext context) {
    switch (step) {
      case DemoAuthStep.starting:
        // Тот же каркас, что и у экранов кода: заголовок с иконкой уже
        // зависят от канала, поэтому здесь нейтральный спиннер — вёрстка
        // не скачет, когда шаг сменится на конкретный.
        return DemoAuthStartingStep(controller: this);
      case DemoAuthStep.sms:
        return DemoSmsStep(
          controller: this,
          smsCodeSource: widget.smsCodeSource,
        );
      case DemoAuthStep.emailCode:
        return DemoEmailCodeStep(controller: this);
      case DemoAuthStep.selectServer:
        return DemoSelectServerStep(controller: this);
    }
  }
}

/// Текст ошибки по коду от сервера.
///
/// Вынесено из состояния экрана: маппинг проверяется тестом напрямую, без
/// поднятия Matrix-клиента, а список кодов должен читаться целиком в одном
/// месте — иначе новый серверный код (так вышло с `otp_rate_limited`) молча
/// падает в общую «что-то пошло не так».
/// Текст известной ошибки сервиса OTP на языке интерфейса.
///
/// `null` — код неизвестен: тогда не показываем НИЧЕГО. Прежде сюда падал
/// сырой ответ сервиса («Otp request limit per hour by email exceeded …
/// Unprocessable Entity») — английский и во внутренних терминах.
String? demoAuthDetailMessage(String code, L10n l10n) => switch (code) {
  'otp_detail_limit_per_hour' => l10n.demoAuthDetailLimitPerHour,
  'otp_detail_attempts_exhausted' => l10n.demoAuthDetailAttemptsExhausted,
  'otp_detail_expired' => l10n.demoAuthDetailExpired,
  'otp_detail_not_found' => l10n.demoAuthDetailNotFound,
  'otp_detail_invalid' => l10n.demoAuthDetailInvalid,
  _ => null,
};

/// Текст ошибки входа на языке интерфейса.
///
/// [passwordChannel] — вход App Store review: сервер отклоняет неверный
/// пароль тем же `invalid_code`, что и OTP, но «Неверный код» на экране
/// пароля сбивает с толку.
String demoAuthErrorMessage(
  String code,
  L10n l10n, {
  bool passwordChannel = false,
}) => switch (code) {
  'invalid_phone' => l10n.demoAuthInvalidPhone,
  'invalid_code' when passwordChannel => l10n.demoAuthWrongPassword,
  'invalid_code' => l10n.demoAuthInvalidCode,
  'otp_expired' => l10n.demoAuthCodeExpired,
  // Оба кода означают одно для человека: код не дошёл не по его вине.
  // `otp_send_failed` — сбой провайдера на /phone/start (bypass выключен),
  // `otp_delivery_failed` — на /phone/verify при включённом bypass.
  'otp_send_failed' || 'otp_delivery_failed' => l10n.demoAuthDeliveryFailed,
  // Серверные лимиты частоты. `otp_rate_limited` — внутренний код
  // старого пути, `otp_request_limit_per_hour` — то, что реально уходит
  // на фронт новым auth-proxy (422, как у otpverification). Для человека
  // это одно и то же: часовой потолок исчерпан, надо подождать.
  'otp_rate_limited' ||
  'otp_request_limit_per_hour' => l10n.demoAuthRateLimited,
  'resend_too_soon' => l10n.demoAuthResendTooSoon,
  'resend_limit_reached' => l10n.demoAuthResendLimitReached,
  'email_send_failed' => l10n.demoAuthEmailSendFailed,
  'invalid_email' => l10n.demoAuthInvalidEmail,
  'otp_attempts_exhausted' => l10n.demoAuthAttemptsExhausted,
  'ticket_expired' => l10n.demoAuthSessionExpired,
  // Keycloak отверг карточку нового пользователя (валидация realm'а:
  // длина номера и т.п.). Раньше приезжал как `keycloak_error` и звучал
  // «сервис недоступен», хотя сервис был жив (LABA-2527).
  'registration_rejected' => l10n.demoAuthRegistrationRejected,
  'keycloak_error' => l10n.demoAuthKeycloakError,
  'synapse_error' => l10n.demoAuthSynapseError,
  _ => l10n.demoAuthGenericError,
};
