import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/widgets/matrix.dart';
import '../../config/themes.dart';
import 'chat.dart';
import 'events/message_link_preview.dart';
import 'events/reply_content.dart';

class ReplyDisplay extends StatelessWidget {
  final ChatController controller;
  const ReplyDisplay(this.controller, {super.key});

  Event? get _editDisplayEvent {
    final editEvent = controller.editEvent;
    final timeline = controller.timeline;
    if (editEvent == null || timeline == null) return editEvent;
    return editEvent.getDisplayEvent(timeline);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Reply/edit имеют приоритет над превью ссылки.
    final showReplyOrEdit =
        controller.editEvent != null || controller.replyEvent != null;
    final linkPreview = showReplyOrEdit ? null : controller.messageLinkPreview;
    final visible = showReplyOrEdit || linkPreview != null;

    return AnimatedContainer(
      duration: LizaThemes.animationDuration,
      curve: LizaThemes.animationCurve,
      height: visible ? 56 : 0,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(color: theme.colorScheme.onInverseSurface),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: L10n.of(context).close,
            icon: const Icon(Icons.close),
            onPressed: linkPreview != null
                ? controller.cancelMessageLinkPreview
                : controller.cancelReplyEventAction,
          ),
          Expanded(
            child: linkPreview != null
                ? MessageLinkPreview(
                    link: linkPreview,
                    client: Matrix.of(context).client,
                  )
                : controller.replyEvent != null
                // timeline == null — штатное окно перезагрузки ленты
                // (scrollDown/scrollToEventId) и dispose; reply/edit при этом
                // остаются выбраны (GlitchTip #605).
                ? ReplyContent(
                    controller.replyEvent!,
                    timeline: controller.timeline,
                  )
                : _EditContent(_editDisplayEvent),
          ),
        ],
      ),
    );
  }
}

class _EditContent extends StatelessWidget {
  final Event? event;

  const _EditContent(this.event);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final event = this.event;
    if (event == null) {
      return const SizedBox.shrink();
    }
    return Row(
      children: <Widget>[
        Icon(Icons.edit, color: theme.colorScheme.primary),
        Container(width: 15.0),
        Text(
          event.calcLocalizedBodyFallback(
            MatrixLocals(L10n.of(context)),
            withSenderNamePrefix: false,
            hideReply: true,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(color: theme.textTheme.bodyMedium!.color),
        ),
      ],
    );
  }
}
