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

/// Стадии загрузки документа, которые движок сообщает хосту. Строки, а не
/// enum: в `error:` уходит код от плагина, и хост пишет стадию в лог как есть.
abstract final class TgWidgetEngineStage {
  /// WebView создан, документ ещё не начал грузиться.
  static const String created = 'created';

  /// Навигация документа началась.
  static const String loadStarted = 'loadStarted';

  /// Документ загружен (шим мог не выполниться — например, при ошибке
  /// компиляции content-rule-list плагин `load` не зовёт вовсе).
  static const String loadStopped = 'loadStopped';

  /// Первое сообщение шима: мост живой, документ действительно выполнился.
  static const String firstMessage = 'firstMessage';

  static String failed(Object code) => 'error:$code';
}

class TgWidgetEngineConfig {
  /// Документ-обёртка (`buildTgWidgetDocument`).
  final String document;

  /// Сырые сообщения шима (JSON-строка). Секрет проверяет сессия.
  final void Function(String raw) onMessage;
  final void Function(TgWidgetEngineHandle handle) onCreated;

  /// Стадия загрузки (см. [TgWidgetEngineStage]). Нужна, чтобы «документ не
  /// запустился» отличалось от «виджет завис после старта»: иначе оба случая
  /// выглядят как остановка по молчанию шима.
  final ValueChanged<String> onStage;

  /// Касания поверх виджета, которые видит Flutter (нативно). Гейт тапа
  /// живёт только здесь: мост виджета — недоверенный канал.
  final ValueChanged<PointerEvent> onPointer;

  /// Развёрнутый вид: документ скроллится. В пузыре профиль 1 без прокрутки.
  final bool scrollable;

  /// Web: пользователь активировал iframe (хостовый сигнал, не из моста).
  final VoidCallback onActivation;

  /// Документ сменился после первой загрузки (навигация в обход шима).
  final VoidCallback onUnexpectedNavigation;

  const TgWidgetEngineConfig({
    required this.document,
    required this.onMessage,
    required this.onCreated,
    required this.onStage,
    required this.onPointer,
    required this.onActivation,
    required this.onUnexpectedNavigation,
    this.scrollable = false,
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
