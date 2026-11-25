import 'package:flutter/material.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/demo_auth/demo_auth_flow.dart';
import 'package:liza/pages/settings_email/sbp_methods.dart';
import 'package:liza/pages/settings_email/settings_email.dart';
import 'package:liza/widgets/matrix.dart';

/// Человекочитаемый текст ошибки: сырой код от сервера показывать нельзя —
/// человек увидел бы «invalid_code» вместо объяснения.
///
/// Коды общие с флоу входа (их отдаёт тот же auth-proxy), поэтому список
/// один: свои остаются только два, специфичных для этого экрана.
String _messageFor(String code, L10n l10n) => switch (code) {
      'email_taken' => l10n.settingsEmailTaken,
      'unauthorized' => l10n.settingsEmailUnauthorized,
      _ => demoAuthErrorMessage(code, l10n),
    };

class SettingsEmailView extends StatelessWidget {
  const SettingsEmailView(this.controller, {super.key});

  final SettingsEmailController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(l10n.settingsEmailTitle),
      ),
      body: ListTileTheme(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (controller.isLoading) const LinearProgressIndicator(),
            switch (controller.step) {
              SettingsEmailStep.overview => _Overview(controller: controller),
              SettingsEmailStep.enterEmail =>
                _EnterEmail(controller: controller),
              SettingsEmailStep.enterCode =>
                _EnterCode(controller: controller),
            },
            if (controller.error != null) ...[
              const SizedBox(height: 16),
              Text(
                _messageFor(controller.error!, l10n),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.controller});

  final SettingsEmailController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final state = controller.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.alternate_email_outlined),
          title: Text(state?.maskedEmail ?? l10n.settingsEmailNotSet),
          subtitle: state?.verified == true
              ? Text(l10n.settingsEmailVerified)
              : null,
        ),
        if (shouldShowEmailReason(state)) ...[
          const SizedBox(height: 16),
          const SettingsEmailReason(),
        ],
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: controller.isLoading ? null : controller.startChange,
          child: Text(l10n.settingsEmailChange),
        ),
        // Счета СБП живут здесь же: «Ваш ID» — про идентичность, а привязка
        // счёта и есть разрешение платить по этому аккаунту в ботах.
        SbpMethodsSection(
          baseUrl: AppConfig.authProxyBaseUrl,
          token: Matrix.of(context).client.accessToken ?? '',
          serverName:
              Matrix.of(context).client.userID?.split(':').last ?? '',
        ),
      ],
    );
  }
}

class _EnterEmail extends StatefulWidget {
  const _EnterEmail({required this.controller});

  final SettingsEmailController controller;

  @override
  State<_EnterEmail> createState() => _EnterEmailState();
}

class _EnterEmailState extends State<_EnterEmail> {
  final TextEditingController _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  bool get _isValid =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_field.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final state = widget.controller.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Здесь условие мягче, чем на overview: до шага ввода можно дойти
        // только через startChange(), т.е. состояние уже загружено, и мигать
        // нечему. Если его всё же нет — показываем, это безопасный дефолт.
        if (state?.verified != true) ...[
          const SettingsEmailReason(),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: _field,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: l10n.settingsEmailEnterAddress,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: widget.controller.isLoading || !_isValid
              ? null
              : () => widget.controller
                  .sendCode(_field.text.trim().toLowerCase()),
          child: Text(l10n.settingsEmailChange),
        ),
      ],
    );
  }
}

class _EnterCode extends StatefulWidget {
  const _EnterCode({required this.controller});

  final SettingsEmailController controller;

  @override
  State<_EnterCode> createState() => _EnterCodeState();
}

class _EnterCodeState extends State<_EnterCode> {
  final TextEditingController _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.settingsEmailEnterCode),
        const SizedBox(height: 16),
        TextField(
          controller: _field,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onChanged: (value) {
            setState(() {});
            if (value.length == 6) widget.controller.verify(value);
          },
        ),
      ],
    );
  }
}

/// Показывать ли обоснование привязки почты.
///
/// Правило одно на оба шага, поэтому вынесено в функцию: подпись нужна лишь
/// тому, у кого запасного входа ещё нет. При подтверждённой почте она молчит,
/// а пока `state == null` (данные грузятся) — не мигает раньше времени.
bool shouldShowEmailReason(AccountEmailState? state) =>
    state != null && !state.verified;

/// Зачем вообще привязывать почту: без этого пояснения шаг выглядит
/// необязательной формальностью, и человек его пропускает — оставаясь без
/// запасного входа, когда СМС не доходит.
///
/// Отдельный виджет, а не строка внутри приватного `_EnterEmail`: так подпись
/// проверяется тестом без поднятия Matrix-клиента и сети.
class SettingsEmailReason extends StatelessWidget {
  const SettingsEmailReason({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      L10n.of(context).settingsEmailReason,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
