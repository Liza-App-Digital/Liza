import 'package:flutter/widgets.dart';

/// Что хост mini App сообщает приложению под собой (Router).
///
/// Кладётся над child в MiniAppOverlay. Уведомляет только при смене флагов, а
/// не на каждый кадр перетаскивания границы.
class MiniAppHostScope extends InheritedWidget {
  /// Рядом открыта боковая панель: приложение остаётся в колоночном режиме,
  /// даже если его ширина опустилась ниже порога двух колонок. Иначе ShellRoute
  /// сменил бы builder посреди перетаскивания (дубль GlobalKey, потеря чата).
  final bool forceColumnMode;

  /// Список чатов свёрнут до колонки аватарок, чтобы дать место панели.
  final bool compactChatList;

  const MiniAppHostScope({
    required this.forceColumnMode,
    required this.compactChatList,
    required super.child,
    super.key,
  });

  static MiniAppHostScope? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MiniAppHostScope>();

  static bool forceColumnModeOf(BuildContext context) =>
      _of(context)?.forceColumnMode ?? false;

  static bool compactChatListOf(BuildContext context) =>
      _of(context)?.compactChatList ?? false;

  @override
  bool updateShouldNotify(MiniAppHostScope oldWidget) =>
      forceColumnMode != oldWidget.forceColumnMode ||
      compactChatList != oldWidget.compactChatList;
}
