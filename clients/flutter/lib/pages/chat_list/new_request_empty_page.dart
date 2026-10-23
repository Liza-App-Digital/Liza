import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/composer_enter_key.dart';
import 'package:liza/utils/liza_new_request.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/update_read_only_bar.dart';

/// Правая панель на компьютере, когда чат не выбран (`/rooms` в column-mode):
/// вместо пустого силуэта — новый запрос к Лизе (задача 14, макет Надежды
/// «Какую задачу решим, Надежда?»). Отправка = «Новый запрос» с этим текстом
/// первым сообщением (`sendNewLizaRequest`).
class NewRequestEmptyPage extends StatefulWidget {
  const NewRequestEmptyPage({super.key});

  @override
  State<NewRequestEmptyPage> createState() => _NewRequestEmptyPageState();
}

/// Имя для заголовка: первое слово displayname. Email/MXID вместо имени и
/// пустое имя — заголовок без обращения.
@visibleForTesting
String? greetingFirstName(String? displayName) {
  final first = (displayName ?? '').trim().split(RegExp(r'\s+')).first;
  if (first.isEmpty || first.contains('@')) return null;
  return first;
}

class _NewRequestEmptyPageState extends State<NewRequestEmptyPage> {
  static const double _maxWidth = 560;

  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onKeyEvent);

  bool _sending = false;

  // Профиль кэшируется на клиента: при смене аккаунта страница не
  // пересоздаётся, а запрос в build на каждый кадр недопустим.
  Client? _profileClient;
  Future<Profile>? _profile;

  Future<Profile>? _ownProfile(Client client) {
    if (!identical(client, _profileClient)) {
      _profileClient = client;
      _profile = client.userID == null ? null : client.fetchOwnProfile();
    }
    return _profile;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (_sending || text.isEmpty) return;
    if (blockedByUpdateReadOnly(context)) return;
    // Флаг — до первого await: Enter приходит в обход кнопки и раньше, чем
    // откроется барьер-диалог.
    setState(() => _sending = true);
    try {
      final opened = await sendNewLizaRequest(context, text);
      // Панель остаётся под открытым чатом в стеке /rooms — без очистки текст
      // встретил бы человека при возврате. При ошибке текст остаётся.
      if (opened && mounted) _controller.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent evt) =>
      composerEnterKey(
        evt,
        _controller.value,
        isMobile: PlatformInfos.isMobile,
        onSend: _send,
      ) ??
      KeyEventResult.ignored;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final client = Matrix.of(context).client;
    return Scaffold(
      // Невидимый appbar, как у EmptyPage: светлый статус-бар на Android-планшетах.
      appBar: AppBar(
        automaticallyImplyLeading: false,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    color: Colors.black,
                    padding: const EdgeInsets.all(8),
                    child: Image.asset(
                      'assets/logo.png',
                      width: 64,
                      height: 64,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                FutureBuilder<Profile>(
                  future: _ownProfile(client),
                  builder: (context, snapshot) {
                    final name = greetingFirstName(snapshot.data?.displayName);
                    return Text(
                      name == null
                          ? l10n.newRequestGreetingNoName
                          : l10n.newRequestGreeting(name),
                      key: const Key('new_request_greeting'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.newRequestSubtitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                ValueListenableBuilder<UpdatePolicy>(
                  valueListenable: UpdatePolicyController.current,
                  builder: (context, policy, _) => policy.readOnly
                      ? const UpdateReadOnlyBar()
                      : _composer(theme, l10n),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _composer(ThemeData theme, L10n l10n) => Container(
    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: theme.colorScheme.primary),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            key: const Key('new_request_field'),
            controller: _controller,
            focusNode: _focusNode,
            readOnly: _sending,
            autofocus: true,
            minLines: 2,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: l10n.newRequestHint,
              border: InputBorder.none,
            ),
          ),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => IconButton.filled(
            key: const Key('new_request_send'),
            tooltip: l10n.send,
            // Барьер-диалога больше нет: пока создаётся чат (~1 с), отклик — здесь.
            icon: _sending
                ? const SizedBox.square(
                    key: Key('new_request_sending'),
                    dimension: 20,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_upward),
            onPressed: _sending || value.text.trim().isEmpty ? null : _send,
          ),
        ),
      ],
    ),
  );
}
