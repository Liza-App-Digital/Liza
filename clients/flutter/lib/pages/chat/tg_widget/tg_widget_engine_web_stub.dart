import 'package:flutter/widgets.dart';

import 'package:liza/pages/chat/tg_widget/tg_widget_engine.dart';

/// Вне Web iframe-движка нет; выбор делает [TgWidgetEngines.builder].
Widget buildWebTgWidgetEngine(TgWidgetEngineConfig config) =>
    const SizedBox.shrink();
