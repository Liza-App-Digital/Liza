import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat/mini_app_manager.dart';

/// Открыть развёрнутый виджет в панели мини-аппа. Одна точка входа для
/// угловой кнопки, пункта меню и `LizaWidget.expand()`.
typedef TgWidgetExpandedOpener =
    void Function(Event event, Timeline? timeline, String title);

void openTgWidgetExpanded(Event event, Timeline? timeline, String title) {
  MiniAppManager.instance.openWidget(event, timeline: timeline, title: title);
}
