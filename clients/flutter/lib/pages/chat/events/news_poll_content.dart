import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/news_poll_results_page.dart';
import 'package:liza/utils/news_poll.dart';
import 'package:liza/widgets/developer_mark.dart';
import 'package:liza/widgets/matrix.dart';

/// Карточка опроса Liza News (`msgtype: com.liza.news.poll`).
///
/// Опрос не анонимный, но обычный пользователь видит ТОЛЬКО свой выбор — ни
/// счётчиков, ни процентов, ни аватарок. Итоги открывает кнопка «Результаты»
/// (видна разработчику; отдаёт их бот, и только разработчикам из списка редакции).
/// Интерактивна лишь от `@liza-news` с ролью `ai` — иначе рисуется body.
class NewsPollContent extends StatefulWidget {
  final Event event;
  final Color textColor;
  final Color linkColor;

  const NewsPollContent({
    required this.event,
    required this.textColor,
    required this.linkColor,
    super.key,
  });

  static const String msgType = newsPollMsgType;

  @override
  State<NewsPollContent> createState() => _NewsPollContentState();
}

class _NewsPollContentState extends State<NewsPollContent> {
  /// Выбор при «несколько ответов» до нажатия «Проголосовать».
  Set<String>? _draft;

  NewsPollData? get _poll => NewsPollData.fromContent(widget.event.content);

  NewsPollService get _service => NewsPollService.of(widget.event.room.client);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final poll = _poll;
    if (poll != null && _trusted(context)) {
      _service.ensureLoaded(widget.event.senderId, poll);
    }
  }

  bool _trusted(BuildContext context) =>
      newsBotMxids.contains(widget.event.senderId) &&
      Matrix.of(context).isAiUser(widget.event.senderId);

  @override
  Widget build(BuildContext context) {
    final roles = Matrix.of(context).userRoleService;
    return ValueListenableBuilder<int>(
      valueListenable: roles.rolesVersion,
      builder: (context, _, _) {
        final poll = _poll;
        if (poll == null || !_trusted(context)) return _fallback();
        return ValueListenableBuilder<NewsPollVoteState>(
          valueListenable: _service.stateOf(poll.pollId),
          builder: (context, state, _) =>
              _buildPoll(context, poll, state, roles.isCurrentUserDeveloper),
        );
      },
    );
  }

  Widget _fallback() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      widget.event.body,
      style: TextStyle(color: widget.textColor, fontSize: 14, height: 1.35),
    ),
  );

  void _vote(NewsPollData poll, List<String> answers) {
    setState(() => _draft = null);
    _service.vote(widget.event.senderId, poll, answers);
  }

  // Тап по закрытому опросу раньше молча игнорировался (onTap: null), и казалось,
  // что выбор «не выбирается» (разбор 2026-09-25) — теперь объясняем.
  void _onTapClosed() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(L10n.of(context).newsPollClosedTap)),
      );
  }

  void _onTapAnswer(NewsPollData poll, NewsPollVoteState state, String id) {
    if (!poll.multiple) {
      if (state.shown.length == 1 && state.shown.first == id) return;
      _vote(poll, [id]);
      return;
    }
    setState(() {
      final draft = _draft ?? state.shown.toSet();
      _draft = draft.contains(id) ? ({...draft}..remove(id)) : {...draft, id};
    });
  }

  Widget _buildPoll(
    BuildContext context,
    NewsPollData poll,
    NewsPollVoteState state,
    bool isDeveloper,
  ) {
    final l10n = L10n.of(context);
    final closed = poll.closed || state.closed;
    final sending = state.status == NewsPollVoteStatus.sending;
    final interactive = !closed && !sending;
    final selected = _draft ?? state.shown.toSet();
    final draftChanged =
        _draft != null && !_sameSet(_draft!, state.shown.toSet());
    final muted = widget.textColor.withValues(alpha: 0.7);

    final status = closed
        ? null
        : switch (state.status) {
            NewsPollVoteStatus.sending => l10n.newsPollSending,
            NewsPollVoteStatus.voted => l10n.newsPollVoteCounted,
            NewsPollVoteStatus.failed => l10n.newsPollVoteFailed,
            NewsPollVoteStatus.idle => null,
          };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (poll.text.isNotEmpty) ...[
              SelectableText(
                poll.text,
                style: TextStyle(
                  color: widget.textColor,
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              poll.question,
              style: TextStyle(
                color: widget.textColor,
                fontWeight: FontWeight.w700,
                fontSize: 15,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              poll.multiple
                  ? '${l10n.newsPollNotAnonymous} · ${l10n.newsPollMultipleHint}'
                  : l10n.newsPollNotAnonymous,
              style: TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 6),
            for (final answer in poll.answers)
              _AnswerRow(
                key: ValueKey('news-poll-answer-${answer.id}'),
                text: answer.text,
                multiple: poll.multiple,
                selected: selected.contains(answer.id),
                dimmed: closed,
                textColor: widget.textColor,
                accent: widget.linkColor,
                onTap: closed
                    ? _onTapClosed
                    : interactive
                    ? () => _onTapAnswer(poll, state, answer.id)
                    : null,
              ),
            if (poll.multiple && draftChanged && interactive)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _vote(poll, _draft!.toList()..sort()),
                  child: Text(l10n.newsPollVote),
                ),
              ),
            if (closed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Container(
                  key: const ValueKey('news-poll-status'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: widget.textColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_outline, size: 14, color: muted),
                      const SizedBox(width: 6),
                      Text(
                        l10n.newsPollClosed,
                        style: TextStyle(
                          color: widget.textColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (status != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  status,
                  key: const ValueKey('news-poll-status'),
                  style: TextStyle(
                    color: state.status == NewsPollVoteStatus.failed
                        ? Theme.of(context).colorScheme.error
                        : muted,
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            if ((state.answers.isNotEmpty && interactive) || isDeveloper)
              Wrap(
                spacing: 4,
                children: [
                  if (state.answers.isNotEmpty && interactive)
                    TextButton(
                      onPressed: () => _vote(poll, const []),
                      child: Text(l10n.newsPollRetractVote),
                    ),
                  if (isDeveloper)
                    TextButton.icon(
                      key: const ValueKey('news-poll-results'),
                      icon: const Icon(Icons.bar_chart_outlined, size: 18),
                      onPressed: () => NewsPollResultsPage.open(
                        context,
                        room: widget.event.room,
                        botMxid: widget.event.senderId,
                        poll: poll,
                      ),
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(l10n.newsPollResults),
                          const SizedBox(width: 6),
                          const DeveloperMark(),
                        ],
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}

class _AnswerRow extends StatelessWidget {
  final String text;
  final bool multiple;
  final bool selected;
  final bool dimmed;
  final Color textColor;
  final Color accent;
  final VoidCallback? onTap;

  const _AnswerRow({
    required this.text,
    required this.multiple,
    required this.selected,
    required this.dimmed,
    required this.textColor,
    required this.accent,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final icon = multiple
        ? (selected ? Icons.check_box : Icons.check_box_outline_blank)
        : (selected
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Opacity(
        opacity: dimmed ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: selected ? accent : textColor.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(color: textColor, fontSize: 14.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
