import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:liza/pages/chat/tg_widget/tg_widget_engine_native.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_engine_web_stub.dart'
    if (dart.library.js_interop) 'package:liza/pages/chat/tg_widget/tg_widget_engine_web.dart';
import 'package:liza/utils/platform_infos.dart';

/// Канал «хост → виджет». Сообщение — уже готовый JSON с секретом.
abstract class TgWidgetEngineHandle {
  Future<void> send(String json);

  /// PNG последнего кадра для постера; `null` — платформа не умеет.
  Future<Uint8List?> snapshot();
}

class TgWidgetEngineConfig {
  /// Документ-обёртка (`buildTgWidgetDocument`).
  final String document;

  /// Сырые сообщения шима (JSON-строка). Секрет проверяет сессия.
  final void Function(String raw) onMessage;
  final void Function(TgWidgetEngineHandle handle) onCreated;

  /// Касания поверх виджета, которые видит Flutter (нативно). Гейт тапа
  /// живёт только здесь: мост виджета — недоверенный канал.
  final ValueChanged<PointerEvent> onPointer;

  /// Web: пользователь активировал iframe (хостовый сигнал, не из моста).
  final VoidCallback onActivation;

  /// Документ сменился после первой загрузки (навигация в обход шима).
  final VoidCallback onUnexpectedNavigation;

  const TgWidgetEngineConfig({
    required this.document,
    required this.onMessage,
    required this.onCreated,
    required this.onPointer,
    required this.onActivation,
    required this.onUnexpectedNavigation,
  });
}

typedef TgWidgetEngineBuilder = Widget Function(TgWidgetEngineConfig config);

/// Выбор движка по платформе. `flutter test` WebView не поднимает — тесты
/// ставят [debugBuilder] (фейковый движок).
abstract final class TgWidgetEngines {
  static TgWidgetEngineBuilder? debugBuilder;

  /// Шов для тестов «Linux / без движка».
  static bool? debugSupported;

  /// Web-iframe: самонавигацию sandbox-iframe не предотвратить (запрос уходит
  /// раньше, чем мы её заметим), поэтому на Web живут только виджеты
  /// проверенных ботов (D, ревью 2026-11-13).
  static bool get liveOnlyForVerified => debugLiveOnlyForVerified ?? kIsWeb;
  static bool? debugLiveOnlyForVerified;

  /// Транспорт шима: `web` — postMessage из sandbox-iframe.
  static bool get isWeb => kIsWeb;

  static bool get supported =>
      debugSupported ?? (debugBuilder != null || !PlatformInfos.isLinux);

  static TgWidgetEngineBuilder get builder =>
      debugBuilder ??
      (kIsWeb ? buildWebTgWidgetEngine : buildNativeTgWidgetEngine);
}
