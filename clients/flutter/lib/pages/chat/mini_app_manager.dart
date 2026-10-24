import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';

/// Сколько ширины боковая панель оставляет приложению при ПОЛНОМ списке чатов:
/// порог двух колонок.
const double kMiniAppMinChildWidth =
    LizaThemes.columnWidth * 2 + LizaThemes.navRailWidth + 1;

/// Ширина боковой панели miniApp по умолчанию (широкое окно).
const double kMiniAppDefaultPanelWidth = 440;

/// С какой ширины окна miniApp по умолчанию открывается закреплённой панелью
/// сбоку, а не на весь экран: двухколоночный режим (841) + панель по умолчанию.
const double kMiniAppDockedByDefaultMinWidth =
    kMiniAppMinChildWidth + kMiniAppDefaultPanelWidth;

/// Описание одного открытого MiniApp-инстанса.
class MiniAppInstance {
  final String appUrl;
  final String appId;
  final String appName;
  final Room room;

  /// 'first_party' (наш доверенный app, прямой WebView) либо 'third_party'
  /// (сторонний код — грузится изолированно через shell + sandboxed iframe).
  final String appType;

  /// Deep-link на конкретную страницу mini App (`#!/tproduct/123`). Пусто —
  /// открываем главную.
  final String appStartPath;

  /// Поколение инстанса: растёт, когда уже открытый app переоткрывают с другим
  /// deep-link. Входит в ключ контента — WebView пересоздаётся на новом пути.
  final int generation;

  MiniAppInstance({
    required this.appUrl,
    required this.appId,
    required this.appName,
    required this.room,
    this.appType = 'first_party',
    this.appStartPath = '',
    this.generation = 0,
  });

  String get contentKey => '$appId#$generation';
}

/// Глобальный менеджер открытых MiniApp.
///
/// Хранит список открытых приложений, активное приложение,
/// состояние развёрнутости. Уведомляет подписчиков (MiniAppOverlay)
/// о любых изменениях.
class MiniAppManager extends ChangeNotifier {
  MiniAppManager._();
  static final MiniAppManager instance = MiniAppManager._();

  final List<MiniAppInstance> _apps = [];
  String? _activeAppId;
  bool _isExpanded = false;
  bool? _fullscreen;

  /// Ширина боковой панели на широком окне. ValueNotifier, а не поле с
  /// notifyListeners: при перетаскивании границы перестраивается только
  /// геометрия, а не весь overlay со всеми WebView.
  final panelWidth = ValueNotifier<double>(kMiniAppDefaultPanelWidth);

  /// Доля высоты miniApp в двойном экране (бегунок на узком окне).
  final splitFraction = ValueNotifier<double>(0.5);

  /// Список чатов сейчас можно свернуть до аватарок: его публикует ChatList
  /// (открыт чат, нет поиска). Только тогда панель тянется дальше порога двух
  /// колонок — в настройках и на пустой /rooms сворачивать нечего.
  final chatListCompactable = ValueNotifier<bool>(false);
  Object? _compactableOwner;

  void publishChatListCompactable(Object owner, bool value) {
    _compactableOwner = owner;
    chatListCompactable.value = value;
  }

  /// Снять признак, если его выставлял именно [owner]: новый ChatList мог уже
  /// опубликовать своё значение в том же кадре.
  void releaseChatListCompactable(Object owner) {
    if (!identical(_compactableOwner, owner)) return;
    _compactableOwner = null;
    chatListCompactable.value = false;
  }

  // Ширина окна из последней раскладки хоста — для «развернуть список».
  double _windowWidth = 0;

  void reportWindowWidth(double width) => _windowWidth = width;

  /// Кнопка «развернуть список» в колонке аватарок: ужать панель так, чтобы
  /// список снова поместился целиком.
  void expandChatList() {
    if (_windowWidth <= 0) return;
    // +1: при дробной ширине окна (масштаб 125%) разность может выйти
    // 840.999… — ниже порога, и список так и не развернулся бы.
    panelWidth.value = _windowWidth - kMiniAppMinChildWidth - 1;
  }

  List<MiniAppInstance> get apps => List.unmodifiable(_apps);
  bool get hasApps => _apps.isNotEmpty;
  int get appCount => _apps.length;
  bool get isExpanded => _isExpanded;

  /// Явный выбор пользователя «на весь экран» / «закреплённый» (боковая панель
  /// на широком окне, двойной экран на узком). null — по умолчанию от ширины.
  bool? get fullscreenPreference => _fullscreen;

  /// Развёрнут ли miniApp на весь экран при данной ширине окна.
  bool isFullscreenFor(double windowWidth) =>
      _fullscreen ?? windowWidth < kMiniAppDockedByDefaultMinWidth;

  void setFullscreen(bool value) {
    if (_fullscreen == value) return;
    _fullscreen = value;
    notifyListeners();
  }

  String? get activeAppId => _activeAppId;

  MiniAppInstance? get activeApp {
    if (_activeAppId == null) return null;
    try {
      return _apps.firstWhere((a) => a.appId == _activeAppId);
    } catch (_) {
      return null;
    }
  }

  /// Открывает miniApp. Если уже открыт — переключает на него и разворачивает.
  void open({
    required String appUrl,
    required String appId,
    required String appName,
    required Room room,
    String appType = 'first_party',
    String appStartPath = '',
  }) {
    final index = _apps.indexWhere((a) => a.appId == appId);
    if (index >= 0) {
      final existing = _apps[index];
      if (appStartPath.isNotEmpty && appStartPath != existing.appStartPath) {
        _apps[index] = MiniAppInstance(
          appUrl: appUrl,
          appId: appId,
          appName: appName,
          room: room,
          appType: appType,
          appStartPath: appStartPath,
          generation: existing.generation + 1,
        );
      }
      _activeAppId = appId;
      _isExpanded = true;
      notifyListeners();
      return;
    }

    if (_apps.isEmpty) _fullscreen = null;
    _apps.add(
      MiniAppInstance(
        appUrl: appUrl,
        appId: appId,
        appName: appName,
        room: room,
        appType: appType,
        appStartPath: appStartPath,
      ),
    );
    _activeAppId = appId;
    _isExpanded = true;
    notifyListeners();
  }

  /// Сворачивает текущий miniApp в плашку.
  void minimize() {
    _isExpanded = false;
    notifyListeners();
  }

  /// Разворачивает miniApp. Если указан appId — переключает на него.
  void expand([String? appId]) {
    if (appId != null && _apps.any((a) => a.appId == appId)) {
      _activeAppId = appId;
    }
    _isExpanded = true;
    notifyListeners();
  }

  /// Закрывает конкретный miniApp.
  void close(String appId) {
    _apps.removeWhere((a) => a.appId == appId);
    if (_activeAppId == appId) {
      _activeAppId = _apps.isNotEmpty ? _apps.last.appId : null;
    }
    if (_apps.isEmpty) {
      _isExpanded = false;
    }
    notifyListeners();
  }

  /// Закрывает miniApp, открытые от имени [client] (выход из аккаунта).
  void closeForClient(Client client) {
    if (!_apps.any((a) => a.room.client == client)) return;
    for (final app in _apps.where((a) => a.room.client == client).toList()) {
      close(app.appId);
    }
  }

  /// Закрывает все miniApp.
  void closeAll() {
    _apps.clear();
    _activeAppId = null;
    _isExpanded = false;
    notifyListeners();
  }

  /// Переключается на следующий miniApp (для свайпа между ними).
  void switchToNext() {
    if (_apps.length <= 1) return;
    final idx = _apps.indexWhere((a) => a.appId == _activeAppId);
    _activeAppId = _apps[(idx + 1) % _apps.length].appId;
    notifyListeners();
  }
}
