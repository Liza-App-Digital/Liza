import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/mxc_image.dart';

/// Куда прижимать ряд реакций.
///
/// В канале — всегда влево: пост канала не считается «своим сообщением»
/// (`message.dart:164` считает так же), и у автора реакции уезжали вправо,
/// отрываясь от поста.
WrapAlignment reactionAlignment({
  required bool ownMessage,
  required bool isChannel,
}) =>
    ownMessage && !isChannel ? WrapAlignment.end : WrapAlignment.start;

class MessageReactions extends StatelessWidget {
  final Event event;
  final Timeline timeline;

  const MessageReactions(this.event, this.timeline, {super.key});

  /// Чипы реакций отдельными виджетами — для раскладок, которым нужно смешать
  /// их с собственным содержимым в ОДНОМ потоке (строка статистики поста
  /// канала кладёт сюда же «просмотры + время»). Готовый `Wrap` из [build]
  /// туда не годится: вложенный `Wrap` схлопнулся бы в минимальную ширину.
  static List<Widget> chipsFor(
    BuildContext context,
    Event event,
    Timeline timeline,
  ) => _buildChips(context, event, timeline);

  @override
  Widget build(BuildContext context) {
    final ownMessage = event.senderId == event.room.client.userID;
    return Wrap(
      spacing: 4.0,
      runSpacing: 4.0,
      alignment: reactionAlignment(
        ownMessage: ownMessage,
        isChannel: event.room.isChannel,
      ),
      children: _buildChips(context, event, timeline),
    );
  }
}

List<Widget> _buildChips(
  BuildContext context,
  Event event,
  Timeline timeline,
) {
  final allReactionEvents = event.aggregatedEvents(
    timeline,
    RelationshipTypes.reaction,
  );
  final reactionMap = <String, _ReactionEntry>{};
  final client = Matrix.of(context).client;

  for (final e in allReactionEvents) {
    final key = e.content
        .tryGetMap<String, dynamic>('m.relates_to')
        ?.tryGet<String>('key');
    if (key != null) {
      if (!reactionMap.containsKey(key)) {
        reactionMap[key] = _ReactionEntry(
          key: key,
          count: 0,
          reacted: false,
          reactors: [],
        );
      }
      reactionMap[key]!.count++;
      reactionMap[key]!.reactors!.add(e.senderFromMemoryOrFallback);
      reactionMap[key]!.reacted |= e.senderId == e.room.client.userID;
    }
  }

  final reactionList = reactionMap.values.toList();
  reactionList.sort((a, b) => b.count - a.count > 0 ? 1 : -1);
  // На каналах, созданных до фикса 2026-08-01 (и не догнанных бэкфиллом),
  // порог m.room.redaction наследует events_default: 100 — сервер отвечает
  // M_FORBIDDEN. Без гейта пользователь тапал уже поставленную реакцию и
  // получал диалог «Нет прав доступа» вместо снятия.
  final canRedactOwnReaction = event.room.canRedactOwnReaction;
  final canInteract =
      canInteractWithReactionsAt(membership: event.room.membership) &&
      !UpdatePolicyController.readOnly;
  return [
    ...reactionList.map(
      (r) => _Reaction(
        reactionKey: r.key,
        count: r.count,
        reacted: r.reacted,
        onTap: !canInteract || (r.reacted && !canRedactOwnReaction)
            ? null
            : () {
                if (r.reacted) {
                  final evt = allReactionEvents.firstWhereOrNull(
                    (e) =>
                        e.senderId == e.room.client.userID &&
                        e.content.tryGetMap('m.relates_to')?['key'] == r.key,
                  );
                  if (evt != null) {
                    showFutureLoadingDialog(
                      context: context,
                      future: () => evt.redactEvent(),
                    );
                  }
                } else {
                  event.room.sendReaction(event.eventId, r.key);
                }
              },
        onLongPress: () async {
          HapticFeedback.heavyImpact();
          await _AdaptableReactorsDialog(
            client: client,
            reactionEntry: r,
          ).show(context);
        },
      ),
    ),
    if (allReactionEvents.any((e) => e.status.isSending))
      const SizedBox(
        width: 24,
        height: 24,
        child: Padding(
          padding: EdgeInsets.all(4.0),
          child: CircularProgressIndicator.adaptive(strokeWidth: 1),
        ),
      ),
  ];
}

class _Reaction extends StatelessWidget {
  final String reactionKey;
  final int count;
  final bool? reacted;
  final void Function()? onTap;
  final void Function()? onLongPress;

  const _Reaction({
    required this.reactionKey,
    required this.count,
    required this.reacted,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget content;
    if (reactionKey.startsWith('mxc://')) {
      content = Row(
        mainAxisSize: .min,
        children: <Widget>[
          MxcImage(
            uri: Uri.parse(reactionKey),
            width: 20,
            height: 20,
            animated: false,
            isThumbnail: false,
          ),
          if (count > 1) ...[
            const SizedBox(width: 4),
            Text(
              count.toString(),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontSize: DefaultTextStyle.of(context).style.fontSize,
              ),
            ),
          ],
        ],
      );
    } else {
      var renderKey = Characters(reactionKey);
      if (renderKey.length > 10) {
        renderKey = renderKey.getRange(0, 9) + Characters('…');
      }
      content = Text(
        renderKey.toString() + (count > 1 ? ' $count' : ''),
        style: TextStyle(
          color: theme.colorScheme.onSurface,
          fontSize: DefaultTextStyle.of(context).style.fontSize,
        ),
      );
    }
    return InkWell(
      onTap: () => onTap != null ? onTap!() : null,
      onLongPress: () => onLongPress != null ? onLongPress!() : null,
      borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
      child: Container(
        decoration: BoxDecoration(
          color: reacted == true
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHigh,
          border: Border.all(
            // Непоставленная реакция раньше имела рамку цвета собственной
            // подложки — на тёмной теме плашка сливалась с постом и эмодзи
            // читался как часть текста. `outlineVariant` тоже оказался
            // недостаточен: замер контраста к surfaceContainerHigh дал
            // 1.54:1 в тёмной теме и 1.39:1 в светлой (едва различимо);
            // `outline` даёт 4.55:1 / 3.66:1 — уверенно видимая граница.
            color: reacted == true
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: content,
      ),
    );
  }
}

class _ReactionEntry {
  String key;
  int count;
  bool reacted;
  List<User>? reactors;

  _ReactionEntry({
    required this.key,
    required this.count,
    required this.reacted,
    this.reactors,
  });
}

class _AdaptableReactorsDialog extends StatelessWidget {
  final Client? client;
  final _ReactionEntry? reactionEntry;

  const _AdaptableReactorsDialog({this.client, this.reactionEntry});

  Future<bool?> show(BuildContext context) => showAdaptiveDialog(
    context: context,
    builder: (context) => this,
    barrierDismissible: true,
    useRootNavigator: false,
  );

  @override
  Widget build(BuildContext context) {
    final body = SingleChildScrollView(
      child: Wrap(
        spacing: 8.0,
        runSpacing: 4.0,
        alignment: WrapAlignment.center,
        children: <Widget>[
          for (final reactor in reactionEntry!.reactors!)
            Chip(
              avatar: Avatar(
                mxContent: reactor.avatarUrl,
                name: reactor.displayName,
                client: client,
                presenceUserId: reactor.stateKey,
                isHexagonal: Matrix.of(context)
                    .isAiUser(reactor.stateKey ?? ''),
              ),
              label: Text(reactor.displayName!),
            ),
        ],
      ),
    );

    final title = Center(child: Text(reactionEntry!.key));

    return AlertDialog.adaptive(title: title, content: body);
  }
}
