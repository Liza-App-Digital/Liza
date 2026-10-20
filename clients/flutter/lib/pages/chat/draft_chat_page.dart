import 'package:flutter/material.dart';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/composer_enter_key.dart';
import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/share_scaffold_dialog.dart';

/// Черновой личный чат: экран открыт, но комнаты ещё НЕТ. Комната создаётся и
/// приглашение уходит собеседнику ТОЛЬКО при отправке первого сообщения
/// (любой контент). До отправки — ни диалога у отправителя, ни запроса у
/// собеседника. См. спеку
/// `docs/superpowers/specs/2026-09-03-direct-chat-draft-on-first-message-design.md`.
///
/// Экран намеренно лёгкий: без таймлайна, ресиптов, typing и read-marker —
/// они появляются уже в реальном `ChatPage` после материализации. Голосовое/
/// стикер как ПЕРВОЕ сообщение доступны в реальном чате после первой отправки
/// текста/медиа.
class DraftChatPage extends StatefulWidget {
  final String userId;
  final Profile? initialProfile;

  const DraftChatPage(this.userId, {this.initialProfile, super.key});

  @override
  State<DraftChatPage> createState() => _DraftChatPageState();
}

class _DraftChatPageState extends State<DraftChatPage> {
  final TextEditingController _textController = TextEditingController();
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onKeyEvent);

  Profile? _profile;

  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    if (_profile == null) _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await Matrix.of(
        context,
      ).client.getProfileFromUserId(widget.userId);
      if (mounted) setState(() => _profile = profile);
    } catch (_) {
      // Профиль не подтянулся (сеть) — покажем MXID, экран остаётся рабочим.
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Материализует комнату и передаёт первое сообщение в реальный `ChatPage`
  /// через штатный канал `shareItems` (тот же, что системный «поделиться»).
  Future<void> _materializeAndGo(List<ShareItem> items) async {
    if (_sending || items.isEmpty) return;
    setState(() => _sending = true);
    final client = Matrix.of(context).client;
    final router = GoRouter.of(context);
    // `ensureDirectChat` идемпотентен (переиспользует существующий DM), сам
    // джойнит invite-DM, пишет `m.direct` и дедупит двойной тап / текст+файл.
    final result = await showFutureLoadingDialog(
      context: context,
      future: () => client.ensureDirectChat(widget.userId),
    );
    if (!mounted) return;
    setState(() => _sending = false);
    final roomId = result.result;
    // Ошибка (federation-fail и т.п.) — showFutureLoadingDialog уже показал её,
    // текст в поле сохранён, комната НЕ создана. Остаёмся в черновике.
    if (roomId == null) return;
    router.go('/rooms/$roomId', extra: items);
  }

  void _sendText() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _materializeAndGo([TextShareItem(text)]);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent evt) =>
      composerEnterKey(
        evt,
        _textController.value,
        isMobile: PlatformInfos.isMobile,
        onSend: _sendText,
      ) ??
      KeyEventResult.ignored;

  Future<void> _attach() async {
    if (_sending) return;
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (picked == null || !mounted) return;
    final items = picked.files
        .where((file) => file.path != null)
        .map<ShareItem>(
          (file) => FileShareItem(XFile(file.path!, name: file.name)),
        )
        .toList();
    if (items.isEmpty) return;
    await _materializeAndGo(items);
  }

  String get _displayName =>
      _profile?.displayName ?? widget.userId.localpart ?? L10n.of(context).user;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Avatar(
              mxContent: _profile?.avatarUrl,
              name: _displayName,
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _displayName,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  l10n.draftChatHint,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: l10n.sendFile,
                    onPressed: _sending ? null : _attach,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      focusNode: _focusNode,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 8,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: l10n.writeAMessage,
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _textController,
                    builder: (context, value, _) {
                      final canSend = value.text.trim().isNotEmpty && !_sending;
                      return IconButton(
                        icon: const Icon(Icons.send_outlined),
                        color: theme.colorScheme.primary,
                        onPressed: canSend ? _sendText : null,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
