import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat/tg_widget/tg_widget_bubble.dart';

/// Развёрнутый виджет в панели мини-аппа.
///
/// Это тот же живой виджет и тот же sandbox, что и в пузыре: код, подпись,
/// тема, tap-гейт и канал запросов берутся из исходного события. Отличается
/// только хост: полная высота панели, вертикальная прокрутка и видимый блок
/// `.liza-more`. Моста mini App, initData и сети здесь нет.
class TgWidgetExpandedView extends StatefulWidget {
  final Event event;
  final Timeline? timeline;
  final String title;

  const TgWidgetExpandedView({
    required this.event,
    required this.timeline,
    required this.title,
    super.key,
  });

  @override
  State<TgWidgetExpandedView> createState() => _TgWidgetExpandedViewState();
}

class _TgWidgetExpandedViewState extends State<TgWidgetExpandedView> {
  StreamSubscription<SyncUpdate>? _sync;

  @override
  void initState() {
    super.initState();
    // Правки chat_data/public_data приходят m.replace в таймлайн: пузырь в
    // ленте перестраивает родитель, а панель живёт отдельно — будим её сами.
    _sync = widget.event.room.client.onSync.stream.listen((update) {
      if (!mounted) return;
      if (update.rooms?.join?.containsKey(widget.event.room.id) ?? false) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    unawaited(_sync?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: widget.title,
      child: ColoredBox(
        color: theme.colorScheme.surface,
        child: TgWidgetBubble(
          key: ValueKey('expanded-${widget.event.eventId}'),
          event: widget.event,
          timeline: widget.timeline,
          ownMessage: false,
          textColor: theme.colorScheme.onSurface,
          linkColor: theme.colorScheme.primary,
          expanded: true,
        ),
      ),
    );
  }
}
