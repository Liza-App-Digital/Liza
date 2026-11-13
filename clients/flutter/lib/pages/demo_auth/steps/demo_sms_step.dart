import 'dart:async';

import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/demo_auth/demo_auth_flow.dart';
import 'package:liza/pages/demo_auth/resend_countdown_format.dart';
import 'package:liza/pages/demo_auth/sms_code_source.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/pages/demo_auth/widgets/code_input.dart';
import 'package:liza/pages/demo_auth/widgets/demo_auth_scaffold.dart';
import 'package:liza/pages/demo_auth/widgets/otp_actions_row.dart';
import 'package:liza/pages/demo_auth/widgets/support_dialog.dart';

/// Шаг 2: код из СМС.
///
/// «СМС не пришло» → таймер обратного отсчёта. Лимит повторов считает
/// сервер (`resend_limit_reached`) — при его исчерпании каркас экрана
/// сам заменяет текст ошибки кнопкой выхода в поддержку.
class DemoSmsStep extends StatefulWidget {
  const DemoSmsStep({super.key, required this.controller, this.smsCodeSource});

  final DemoAuthFlowController controller;

  /// Источник кода из входящей СМС. По умолчанию — системный диалог на
  /// Android, на остальных платформах его нет (iOS подставляет код сама
  /// через `oneTimeCode` у ячейки).
  final SmsCodeSource? smsCodeSource;

  @override
  State<DemoSmsStep> createState() => _DemoSmsStepState();
}

class _DemoSmsStepState extends State<DemoSmsStep> {
  /// Запасное значение: сервер обычно присылает `resend_available_in`, но
  /// на старых сборках auth-proxy поля нет — тогда считаем сами.
  static const _resendDelaySeconds = 60;

  Timer? _timer;
  int _secondsLeft = 0;

  /// Эпоха серверного значения, по которой отсчёт уже запущен.
  int _seenEpoch = -1;

  final _feed = CodeInputFeed();
  SmsCodeSource? _smsSource;

  /// Номер ожидания: опоздавший ответ от прежней регистрации игнорируется.
  int _listenGeneration = 0;

  @override
  void initState() {
    super.initState();
    _smsSource =
        widget.smsCodeSource ??
        (PlatformInfos.isAndroid ? AndroidSmsCodeSource() : null);
    _syncCountdown();
  }

  /// Ждём СМС только пока код реально ушёл СМС: для письма, входа по паролю
  /// и во время проверки системный диалог человеку не нужен.
  Future<void> _listenForSms() async {
    final source = _smsSource;
    final generation = ++_listenGeneration;
    if (source == null) return;
    await source.cancel();
    final controller = widget.controller;
    if (!mounted ||
        generation != _listenGeneration ||
        controller.passwordLogin ||
        controller.smsCodeSentByEmail) {
      return;
    }
    final code = await source.next();
    if (code == null || !mounted || generation != _listenGeneration) return;
    if (widget.controller.isLoading) return;
    _feed.push(code);
  }

  @override
  void didUpdateWidget(DemoSmsStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncCountdown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _listenGeneration++;
    _smsSource?.cancel();
    super.dispose();
  }

  /// Перезапускает отсчёт от серверного лимита, и ТОЛЬКО по новому ответу
  /// сервера (эпоха контроллера). Сравнение по значению здесь не годится:
  /// «больше текущего» не давало ответу «60 с» пробить остаток старого
  /// часового лимита после «Отправить ещё раз», а любая перерисовка
  /// контроллера (неверный код на 0:30) отбрасывала отсчёт к 1:00.
  void _syncCountdown() {
    final controller = widget.controller;
    // Повтора у входа по паролю нет — и таймеру отсчитывать нечего.
    if (controller.passwordLogin) {
      _timer?.cancel();
      _secondsLeft = 0;
      return;
    }
    if (controller.resendEpoch == _seenEpoch) return;
    _seenEpoch = controller.resendEpoch;
    _listenForSms();
    final fromServer = controller.resendAvailableIn;
    if (fromServer == null) {
      _startCountdown();
    } else if (fromServer > 0) {
      _startCountdown(fromServer);
    } else {
      _timer?.cancel();
      _secondsLeft = 0;
    }
  }

  /// Запускает отсчёт. Перерисовку НЕ дёргает сам: вызывается в том числе
  /// из initState, где setState запрещён — обновление приезжает либо
  /// первым build, либо ближайшим тиком таймера.
  void _startCountdown([int? seconds]) {
    _secondsLeft = seconds ?? _resendDelaySeconds;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _secondsLeft--;
        if (_secondsLeft <= 0) timer.cancel();
      });
    });
  }

  // Отсчёт здесь заранее не запускаем: на время запроса зону таймера
  // закрывает спиннер, а новое значение придёт от сервера новой эпохой.
  Future<void> _resend() => widget.controller.resendSms();

  Future<void> _switchChannel(DemoAuthChannel channel) =>
      widget.controller.switchChannel(channel);

  Widget _resendArea(L10n l10n, DemoAuthFlowController controller) {
    if (controller.errorCode == 'resend_limit_reached') {
      return ElevatedButton.icon(
        icon: const Icon(Icons.support_agent),
        label: Text(l10n.supportContactButton),
        onPressed: () => showSupportDialog(
          context,
          ticket: controller.ticket,
          step: 'sms',
          errorCode: controller.errorCode,
        ),
      );
    }
    if (_secondsLeft > 0) {
      // Размер подзаголовка, а не bodySmall: пока идёт отсчёт, это главный
      // текст экрана после самого поля кода — по нему человек понимает,
      // когда сможет действовать. Ряд кнопок ниже намеренно мельче.
      return Text(
        l10n.demoAuthResendIn(formatResendCountdown(_secondsLeft)),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    // «Отправить ещё раз», а не «СМС не пришло»: кнопка называется
    // действием, которое выполняет, — про сам факт неполучения человек и
    // так знает, раз до неё дошёл. Текст один на оба канала, поэтому
    // ветвление по smsCodeSentByEmail здесь больше не нужно.
    return TextButton.icon(
      onPressed: widget.controller.isLoading ? null : _resend,
      icon: const Icon(Icons.refresh),
      label: Text(l10n.demoAuthResendAgain),
    );
  }

  /// Номер App Store review: вместо ячеек кода — поле пароля. Таймера,
  /// «Отправить ещё раз» и «Другого способа» нет — кода не было вовсе;
  /// выход в поддержку остаётся.
  Widget _buildPasswordStep(L10n l10n, DemoAuthFlowController controller) {
    return DemoAuthScaffold(
      title: l10n.demoAuthPasswordTitle,
      subtitle: l10n.demoAuthPasswordHint(controller.maskedPhone),
      icon: const Icon(Icons.lock_outline, size: 56),
      onBack: controller.back,
      error: controller.error,
      errorCode: controller.errorCode,
      ticket: controller.ticket,
      step: 'sms',
      showBottomSupport: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DemoPasswordInput(
            // Как у ячеек кода: отказ сервера пересоздаёт поле пустым.
            key: ValueKey(controller.codeRejections),
            autofocus:
                controller.codeRejections == 0 ||
                controller.focusCodeAfterReject,
            isLoading: controller.isLoading,
            onSubmit: controller.submitSmsCode,
          ),
          const SizedBox(height: 8),
          OtpActionsRow(
            step: 'sms',
            ticket: controller.ticket,
            errorCode: controller.errorCode,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final controller = widget.controller;

    if (controller.passwordLogin) return _buildPasswordStep(l10n, controller);

    return DemoAuthScaffold(
      title: controller.smsCodeSentByEmail
          ? l10n.demoAuthEmailCodeTitle
          : l10n.demoAuthSmsTitle,
      subtitle: controller.deliveryFailed
          ? (controller.deliveryRateLimited
                ? l10n.demoAuthRateLimited
                : l10n.demoAuthDeliveryFailed)
          : controller.smsCodeSentByEmail
          // Код ушёл письмом: показывать «мы отправили СМС на номер» и
          // маску адреса рядом было бы прямым враньём.
          ? l10n.demoAuthEmailCodeHint(controller.maskedPhone)
          : l10n.demoAuthSmsHint(controller.maskedPhone),
      subtitleIsWarning: controller.deliveryFailed,
      // Ответ самого otpverification: конкретнее нашей формулировки
      // («limit per hour exceeded» против «не удалось отправить»).
      // Показываем СВОЙ текст по коду, а не ответ сервиса: он на
      // английском и во внутренних терминах. Код неизвестен — строки
      // нет вовсе, лучше пусто, чем чужой язык.
      subtitleDetail: controller.deliveryFailed
          ? demoAuthDetailMessage(controller.deliveryDetailCode, l10n)
          : null,
      // Иконка по каналу: конверт для письма, облачко для СМС. Жёсткий
      // sms_outlined противоречил заголовку «Код подтверждения» и тексту
      // про почту.
      icon: Icon(
        controller.smsCodeSentByEmail
            ? Icons.mark_email_unread_outlined
            : Icons.sms_outlined,
        size: 56,
      ),
      onBack: controller.back,
      error: controller.error,
      errorCode: controller.errorCode,
      ticket: controller.ticket,
      step: 'sms',
      // Выход в поддержку даёт OtpActionsRow под полем кода —
      // нижняя кнопка каркаса стала бы вторым таким же рядом.
      showBottomSupport: false,
      child: Column(
        children: [
          CodeInput(
            // Отказ сервера меняет ключ — ячейки пересоздаются пустыми.
            // Фокус к этому моменту уже снят (последняя ячейка делает
            // unfocus, на время проверки поле выключено), поэтому
            // клавиатура от пересоздания не мигает.
            key: ValueKey(controller.codeRejections),
            autofocus:
                controller.codeRejections == 0 ||
                controller.focusCodeAfterReject,
            // 6, как и код из письма: otpverification шлёт шестизначные
            // коды на оба канала. С пятью ячейками последняя цифра просто
            // некуда было ввести.
            length: 6,
            feed: _feed,
            enabled: !controller.isLoading,
            onCompleted: controller.submitSmsCode,
          ),
          const SizedBox(height: 24),
          if (controller.isLoading)
            const CircularProgressIndicator()
          else
            _resendArea(l10n, controller),
          const SizedBox(height: 8),
          OtpActionsRow(
            step: 'sms',
            ticket: controller.ticket,
            errorCode: controller.errorCode,
            channels: controller.availableChannels,
            currentChannel: controller.currentChannel,
            onSelectChannel: controller.canSwitchChannel
                ? _switchChannel
                : null,
          ),
        ],
      ),
    );
  }
}

/// Поле пароля входа App Store review и кнопка отправки.
///
/// Пароль набирают вручную из заметок App Review, поэтому любые символы (не
/// только цифры), без автокоррекции и подсказок — они «исправили» бы
/// случайную строку. Переключатель видимости — чтобы проверить набранное.
class DemoPasswordInput extends StatefulWidget {
  const DemoPasswordInput({
    super.key,
    required this.onSubmit,
    this.isLoading = false,
    this.autofocus = true,
  });

  final ValueChanged<String> onSubmit;
  final bool isLoading;
  final bool autofocus;

  @override
  State<DemoPasswordInput> createState() => _DemoPasswordInputState();
}

class _DemoPasswordInputState extends State<DemoPasswordInput> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSubmit => !widget.isLoading && _controller.text.isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    widget.onSubmit(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AutofillGroup(
          child: TextField(
            controller: _controller,
            autofocus: widget.autofocus,
            enabled: !widget.isLoading,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.demoAuthPasswordLabel,
              prefixIcon: const Icon(Icons.lock_outline),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              suffixIcon: IconButton(
                tooltip: _obscure
                    ? l10n.showPassword
                    : l10n.demoAuthHidePassword,
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          onPressed: _canSubmit ? _submit : null,
          child: widget.isLoading
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.demoAuthContinue),
        ),
      ],
    );
  }
}
