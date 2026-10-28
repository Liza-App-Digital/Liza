import 'dart:async';

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

  /// Открыт отдельным окном ОС (десктоп), а не панелью в окне Лизы.
  final bool detached;

  MiniAppInstance({
    required this.appUrl,
    required this.appId,
    required this.appName,
    required this.room,
    this.appType = 'first_party',
    this.appStartPath = '',
    this.generation = 0,
    this.detached = false,
  });

  String get contentKey => '$appId#$generation';

  /// Тот же app на новом месте или пути — с новым поколением: контент
  /// пересоздаётся (другой движок или новый deep-link).
  MiniAppInstance moved({String? appStartPath, bool? detached}) =>
      MiniAppInstance(
        appUrl: appUrl,
        appId: appId,
        appName: appName,
        room: room,
        appType: appType,
        appStartPath: appStartPath ?? this.appStartPath,
        generation: generation + 1,
        detached: detached ?? this.detached,
      );
}

/// Глобальный менеджер открытых MiniApp.
///
/// Хранит список открытых приложений, активное приложение,
/// состояние развёрнутости. Уведомляет подписчиков (MiniAppOverlay)
/// о любых изменениях.
///
/// [apps], [hasApps], [activeApp], [isExpanded] — про то, что показано В ОКНЕ
/// Лизы (панель, плашка). Открепленные в окна ОС — в [detachedApps], их окнами
/// управляет `MiniAppWindows`.
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

  /// Отдельные окна ОС поддержаны (macOS/Windows, выставляет `main`): mini App
  /// по умолчанию открывается окном, в шапке панели есть «Открепить».
  bool windowsSupported = false;

  final _focusRequests = StreamController<String>.broadcast();

  /// appId уже открепленного app, который открыли снова: его окно надо поднять.
  Stream<String> get windowFocusRequests => _focusRequests.stream;

  Iterable<MiniAppInstance> get _docked => _apps.where((a) => !a.detached);

  List<MiniAppInstance> get apps => List.unmodifiable(_docked);
  List<MiniAppInstance> get detachedApps =>
      List.unmodifiable(_apps.where((a) => a.detached));
  bool get hasApps => _docked.isNotEmpty;
  int get appCount => _docked.length;
  bool get isExpanded => _isExpanded;

  /// Явный выбор пользователя «на весь экран» / «закреплённый» (боковая панель
  /// на широком окне, двойной экран на узком). null — по умолчанию от ширины.
  bool? get fullscreenPreference => _fullscreen;

  /// Развёрнут ли miniApp на весь экран при данной ширине окна.
  /// Планшет по умолчанию — на весь экран при любой ширине.
  bool isFullscreenFor(double windowWidth, {bool tablet = false}) =>
      _fullscreen ?? (tablet || windowWidth < kMiniAppDockedByDefaultMinWidth);

  void setFullscreen(bool value) {
    if (_fullscreen == value) return;
    _fullscreen = value;
    notifyListeners();
  }

  String? get activeAppId => _activeAppId;

  MiniAppInstance? get activeApp {
    if (_activeAppId == null) return null;
    return _docked.where((a) => a.appId == _activeAppId).firstOrNull;
  }

  /// Открывает miniApp. Если уже открыт — переключает на него и разворачивает
  /// (открепленный — поднимает его окно).
  ///
  /// [allowDetach] = false — только панелью (включён пин-код: окно ОС вне
  /// экрана блокировки).
  void open({
    required String appUrl,
    required String appId,
    required String appName,
    required Room room,
    String appType = 'first_party',
    String appStartPath = '',
    bool allowDetach = true,
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
          detached: existing.detached,
        );
      }
      if (existing.detached) {
        _focusRequests.add(appId);
      } else {
        _activeAppId = appId;
        _isExpanded = true;
      }
      notifyListeners();
      return;
    }

    final detached = windowsSupported && allowDetach;
    if (!detached && !hasApps) _fullscreen = null;
    _apps.add(
      MiniAppInstance(
        appUrl: appUrl,
        appId: appId,
        appName: appName,
        room: room,
        appType: appType,
        appStartPath: appStartPath,
        detached: detached,
      ),
    );
    if (!detached) {
      _activeAppId = appId;
      _isExpanded = true;
    }
    notifyListeners();
  }

  /// Открепить app из панели в отдельное окно ОС. [startPath] — страница, на
  /// которой он сейчас (окно откроется на ней же).
  void detach(String appId, {String? startPath}) {
    final index = _apps.indexWhere((a) => a.appId == appId && !a.detached);
    if (index < 0) return;
    _apps[index] = _apps[index].moved(appStartPath: startPath, detached: true);
    _pickDockedActive();
    notifyListeners();
  }

  /// Вернуть app из окна ОС панелью в окно Лизы.
  void attach(String appId, {String? startPath}) {
    final index = _apps.indexWhere((a) => a.appId == appId && a.detached);
    if (index < 0) return;
    if (!hasApps) _fullscreen = null;
    _apps[index] = _apps[index].moved(appStartPath: startPath, detached: false);
    _activeAppId = appId;
    _isExpanded = true;
    notifyListeners();
  }

  /// Активный в панели ушёл (закрыт/откреплён) — активным становится последний
  /// оставшийся в панели.
  void _pickDockedActive() {
    if (activeApp != null) return;
    _activeAppId = _docked.lastOrNull?.appId;
    if (_activeAppId == null) _isExpanded = false;
  }

  /// Сворачивает текущий miniApp в плашку.
  void minimize() {
    _isExpanded = false;
    notifyListeners();
  }

  /// Разворачивает miniApp. Если указан appId — переключает на него.
  void expand([String? appId]) {
    if (appId != null && _docked.any((a) => a.appId == appId)) {
      _activeAppId = appId;
    }
    _isExpanded = true;
    notifyListeners();
  }

  /// Закрывает конкретный miniApp.
  void close(String appId) {
    _apps.removeWhere((a) => a.appId == appId);
    _pickDockedActive();
    notifyListeners();
  }

  /// Закрывает miniApp, открытые от имени [client] (выход из аккаунта).
  void closeForClient(Client client) {
    if (!_apps.any((a) => a.room.client == client)) return;
    for (final app in _apps.where((a) => a.room.client == client).toList()) {
      close(app.appId);
    }
  }

  /// Закрывает всё, что в окне Лизы (крестик плашки); окна ОС не трогает.
  void closeDocked() {
    _apps.removeWhere((a) => !a.detached);
    _activeAppId = null;
    _isExpanded = false;
    notifyListeners();
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
    final docked = _docked.toList();
    if (docked.length <= 1) return;
    final idx = docked.indexWhere((a) => a.appId == _activeAppId);
    _activeAppId = docked[(idx + 1) % docked.length].appId;
    notifyListeners();
  }
}
