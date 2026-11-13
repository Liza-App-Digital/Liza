import 'dart:async';

import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/bot_interactive_draft.dart';
import 'package:liza/utils/bot_interactive_consent.dart';
import 'package:liza/utils/bot_interactive_inline.dart';
import 'package:liza/utils/bot_interactive_keyboard_state.dart';
import 'package:liza/utils/bot_interactive_markup.dart';
import 'package:liza/utils/bot_interactive_picker.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/widgets/interactive_reply_keyboard.dart';

/// Клавиатура живёт у композера, а не у исторического пузыря сообщения.
class InteractiveBotComposer extends StatefulWidget {
  final Room room;
  final Timeline? timeline;
  final TextEditingController controller;
  final ValueChanged<Event> onForceReply;
  final Future<void> Function(MiniAppLaunch) onOpenApp;
  final VoidCallback onSent;
  final ValueChanged<String>? onDraftChanged;
  const InteractiveBotComposer({
    required this.room,
    required this.timeline,
    required this.controller,
    required this.onForceReply,
    required this.onOpenApp,
    required this.onSent,
    this.onDraftChanged,
    super.key,
  });

  @override
  State<InteractiveBotComposer> createState() => _InteractiveBotComposerState();
}

class _InteractiveBotComposerState extends State<InteractiveBotComposer> {
  late BotInteractiveApi _api;
  late BotInlineController _inline;
  Event? _source;
  BotReplyMarkup? _markup;
  RegisteredBot? _bot;
  int _generation = 0;
  String _signature = '';
  bool _busy = false;
  final Set<String> _consumed = {};

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _api = BotInteractiveApi(widget.room.client);
    _inline = BotInlineController(
      api: _api,
      roomId: widget.room.id,
      send: (content, txid) => widget.room.sendEvent(content, txid: txid),
    );
    _inline.addListener(_changed);
    widget.controller.addListener(_textChanged);
    BotInteractiveDraft.register(
      widget.room.client,
      widget.room.id,
      _applyInlineDraft,
    );
    BotInteractiveDraft.registerQuery(
      widget.room.client,
      widget.room.id,
      // Отправку держим, только пока на экране есть варианты бота: «@бот текст» без
      // вариантов (бот не ответил, ответил пустым или ещё думает) уходит обычным
      // сообщением — иначе упоминание в начале строки отправить было нельзя.
      () => mounted && _api.isCurrent && _inline.results.isNotEmpty,
    );
    _refresh();
    _textChanged();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _textChanged() => _inline.update(widget.controller.text);

  void _applyInlineDraft(String text) {
    if (!mounted || !_api.isCurrent) return;
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    widget.onDraftChanged?.call(text);
  }

  void _detach(TextEditingController controller) {
    ++_generation;
    controller.removeListener(_textChanged);
    BotInteractiveDraft.unregister(
      _api.client,
      _inline.roomId,
      _applyInlineDraft,
    );
    _inline.removeListener(_changed);
    _inline.dispose();
    // Отмена HTTP query получает шанс завершиться до закрытия транспорта.
  }

  @override
  void didUpdateWidget(InteractiveBotComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room.id != widget.room.id ||
        !identical(oldWidget.room.client, widget.room.client) ||
        oldWidget.controller != widget.controller ||
        !_api.isCurrent) {
      _detach(oldWidget.controller);
      _source = null;
      _markup = null;
      _bot = null;
      _signature = '';
      _consumed.clear();
      _attach();
    } else {
      _refresh();
    }
  }

  /// HTTP-success (sent) уже подтверждён сервером до следующего sync.
  /// Локальные sending/error echoes не закрывают одноразовый запрос.
  bool _hasConfirmedReply(Event source) =>
      widget.timeline?.events.any(
        (event) =>
            event.senderId == widget.room.client.userID &&
            event.status.isSent &&
            event.originServerTs.isAfter(source.originServerTs) &&
            event.content['m.relates_to'] is Map &&
            (event.content['m.relates_to'] as Map)['m.in_reply_to'] is Map &&
            ((event.content['m.relates_to'] as Map)['m.in_reply_to']
                    as Map)['event_id'] ==
                source.eventId,
      ) ??
      false;

  void _refresh() {
    final timeline = widget.timeline;
    if (timeline == null) return;
    final seenBots = <String>{};
    final candidates = <Event>[];
    for (final original in timeline.events) {
      final event = original.getDisplayEvent(timeline);
      final parsed = BotReplyMarkup.parse(event.content['com.liza.bot_markup']);
      if (parsed?.selective == true) {
        final mentions = event.content['m.mentions'];
        final mentioned =
            mentions is Map &&
            mentions['user_ids'] is List &&
            (mentions['user_ids'] as List).contains(widget.room.client.userID);
        final relation = event.content['m.relates_to'];
        final reply = relation is Map ? relation['m.in_reply_to'] : null;
        final replyId = reply is Map ? reply['event_id'] : null;
        final repliesToMe =
            replyId is String &&
            timeline.events.any(
              (e) =>
                  e.eventId == replyId &&
                  e.senderId == widget.room.client.userID,
            );
        if (!mentioned && !repliesToMe) continue;
      }
      if (event.senderId != original.senderId ||
          event.senderId == widget.room.client.userID ||
          event.content['com.liza.bot_markup'] == null ||
          !seenBots.add(event.senderId)) {
        continue;
      }
      candidates.add(event);
      if (candidates.length >= 20) break;
    }
    final signature = candidates
        .map(
          (e) =>
              '${e.eventId}:${e.content['com.liza.bot_markup']}:${_hasConfirmedReply(e)}:${BotInteractiveKeyboardState.isConsumed(widget.room, e.eventId)}',
        )
        .join('|');
    if (_signature == signature) return;
    _signature = signature;
    final generation = ++_generation;
    _source = null;
    _markup = null;
    _bot = null;
    unawaited(_loadKeyboard(generation, candidates));
  }

  Future<void> _loadKeyboard(int generation, List<Event> candidates) async {
    if (candidates.isEmpty) return;
    // Кэш account_data из sync уже скрывает использованные клавиатуры; сетевое
    // чтение не задерживает показ, а лишь доскрывает при расхождении.
    final needsState = candidates.any((e) {
      final markup = BotReplyMarkup.parse(e.content['com.liza.bot_markup']);
      return markup != null && (markup.oneTime || markup.forceReply);
    });
    if (needsState) {
      unawaited(
        BotInteractiveKeyboardState.restore(widget.room).then((_) {
          if (mounted && generation == _generation) _refresh();
        }),
      );
    }
    for (final event in candidates) {
      final markup = BotReplyMarkup.parse(event.content['com.liza.bot_markup']);
      if (markup == null ||
          markup.remove ||
          (_consumed.contains(event.eventId) ||
              BotInteractiveKeyboardState.isConsumed(
                widget.room,
                event.eventId,
              ))) {
        continue;
      }
      // Уже отправленный ответ закрывает одноразовую клавиатуру/ForceReply и
      // после повторного входа в чат, без непроверенного постоянного grant.
      if ((markup.oneTime || markup.forceReply) && _hasConfirmedReply(event)) {
        continue;
      }
      RegisteredBot? bot;
      try {
        bot = await _api.resolve(mxid: event.senderId);
      } catch (_) {
        continue;
      }
      if (!mounted || generation != _generation || !_api.isCurrent) return;
      if (bot == null || !bot.supportsInteractive) continue;
      if (markup.forceReply) {
        if (markup.rows.isEmpty) _consumed.add(event.eventId);
        widget.onForceReply(event);
        if (markup.rows.isEmpty) return;
      }
      setState(() {
        _source = event;
        _markup = markup;
        _bot = bot;
      });
      return;
    }
  }

  Future<void> _tap(BotKeyboardButton button) async {
    final source = _source;
    final bot = _bot;
    if (_busy || source == null || bot == null) return;
    final generation = _generation;
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    final sourceRoute = ModalRoute.of(context);
    bool current() =>
        mounted &&
        generation == _generation &&
        _api.isCurrent &&
        source.eventId == _source?.eventId &&
        DateTime.now().isBefore(deadline);
    setState(() => _busy = true);
    try {
      // Проверяем реестр заново перед чувствительным действием.
      final freshBot = await _api.resolve(mxid: bot.mxid, force: true);
      if (freshBot == null || !freshBot.supportsInteractive || !current()) {
        return;
      }
      Map<String, dynamic>? content;
      switch (button.action) {
        case 'text':
          content = {'msgtype': 'm.text', 'body': button.text};
        case 'request_contact':
          final result = await requestBotContact(
            context: context,
            client: widget.room.client,
            recipient: bot.mxid,
            isCurrent: current,
          );
          if (!current()) return;
          if (result.status == BotContactStatus.unavailable) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(L10n.of(context).botContactUnavailable)),
            );
          }
          content = result.content;
        case 'request_location':
          content = await requestBotLocation(
            context: context,
            recipient: bot.mxid,
            isCurrent: current,
          );
        case 'web_app':
          final launch = freshBot.appForUrl(
            button.parameters?['url'] as String? ?? '',
          );
          if (launch == null || !current()) return;
          await widget.onOpenApp(launch);
          return;
        case 'request_users':
        case 'request_chat':
          final index = _markup!.rows
              .expand((row) => row)
              .toList()
              .indexOf(button);
          final query = await _api.request(
            'POST',
            '/liza/interactive/query',
            body: {
              'kind': 'keyboard',
              'room_id': widget.room.id,
              'bot_mxid': bot.mxid,
              'session_id': _inline.sessionId,
              'event_id': source.eventId,
              'button_index': index,
            },
          );
          final id = query['query_id'];
          if (id is! String) return;
          try {
            if (!current()) return;
            final sent = await submitBotKeyboardSelection(
              context: context,
              api: _api,
              room: widget.room,
              queryId: id,
              sessionId: _inline.sessionId,
              button: button,
              isCurrent: current,
            );
            if (sent && current() && _markup?.oneTime == true) {
              // Личный account_data не раскрывает выбранных пользователей/чат.
              // Ошибка его записи не отменяет уже принятый ботом submit.
              unawaited(
                BotInteractiveKeyboardState.remember(
                  widget.room,
                  source.eventId,
                ),
              );
              _consumed.add(source.eventId);
              setState(() {
                _source = null;
                _markup = null;
                _bot = null;
              });
            }
          } finally {
            try {
              await _api.request(
                'POST',
                '/liza/interactive/query/${Uri.encodeComponent(id)}/cancel',
                body: {'session_id': _inline.sessionId},
              );
            } catch (_) {}
          }
          return;
        default:
          throw StateError('Unsupported keyboard request');
      }
      if (content == null ||
          !current() ||
          (sourceRoute != null && !sourceRoute.isCurrent) ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden) {
        return;
      }
      final eventId = await widget.room.sendEvent(
        Map.of(content),
        inReplyTo: source,
      );
      if (!current()) return;
      if (eventId == null || eventId.isEmpty) {
        throw StateError('Message not sent');
      }
      if (_markup?.oneTime == true) {
        _consumed.add(source.eventId);
        setState(() {
          _source = null;
          _markup = null;
          _bot = null;
        });
      }
    } catch (_) {
      if (current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).botInteractiveFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _detach(widget.controller);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final markup = _markup;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_inline.loading) const LinearProgressIndicator(),
        if (_inline.failed) Text(L10n.of(context).botInteractiveFailed),
        if (_inline.results.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final result in _inline.results)
                  ListTile(
                    title: Text(result.title),
                    subtitle: Text(
                      result.content['body'] as String,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    enabled: !_inline.sending,
                    onTap: () async {
                      final text = widget.controller.text;
                      if (await _inline.choose(result) &&
                          mounted &&
                          text == widget.controller.text) {
                        widget.controller.clear();
                        widget.onSent();
                      }
                    },
                  ),
              ],
            ),
          ),
        if (markup != null)
          InteractiveReplyKeyboard(
            rows: markup.rows,
            busy: _busy,
            semanticsLabel: L10n.of(context).botReplyKeyboard,
            onTap: _tap,
          ),
      ],
    );
  }
}
