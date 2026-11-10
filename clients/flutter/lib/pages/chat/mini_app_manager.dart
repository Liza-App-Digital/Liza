import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/pages/chat/mini_app_interactive.dart';
import 'package:liza/utils/fluid_page.dart';

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

/// Что показывает панель: mini App (WebView по URL) либо «жидкая» HTML-страница
/// из события чата (ответ ИИ-бота, см. FluidPageView).
enum MiniAppKind { miniApp, html }

/// Идентификатор панели с HTML-страницей: одна на окно, новая страница
/// заменяет прежнюю.
const String kFluidPageAppId = 'liza-page';

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
  final String startParam;
  final String? botMxid;
  final String? joinRequestQueryId;
  final String interactiveSessionId;
  final MiniAppInteractiveState interactiveState;
  final String? accountUserId;
  final String? accountToken;

  /// Поколение инстанса: растёт, когда уже открытый app переоткрывают с другим
  /// deep-link. Входит в ключ контента — WebView пересоздаётся на новом пути.
  final int generation;

  /// Открыт отдельным окном ОС (десктоп), а не панелью в окне Лизы.
  final bool detached;

  /// Для [MiniAppKind.html] — событие `m.file` text/html с маркером
  /// `com.liza.page`; [appUrl] тогда равен его eventId. null — страница ещё
  /// собирается (панель «собираю», [appUrl] = `pending:<eventId обещания>`).
  final MiniAppKind kind;
  final Event? pageEvent;

  MiniAppInstance({
    required this.appUrl,
    required this.appId,
    required this.appName,
    required this.room,
    this.appType = 'first_party',
    this.appStartPath = '',
    this.startParam = '',
    this.botMxid,
    this.joinRequestQueryId,
    String? interactiveSessionId,
    this.generation = 0,
    this.detached = false,
    this.kind = MiniAppKind.miniApp,
    this.pageEvent,
  }) : interactiveSessionId = interactiveSessionId ?? miniAppCapability(),
       interactiveState = MiniAppInteractiveState()..setVisible(!detached),
       accountUserId = room.client.userID,
       accountToken = room.client.accessToken;

  String get contentKey => '$appId#$generation';

  bool get sessionCurrent =>
      interactiveState.active &&
      accountUserId == room.client.userID &&
      accountToken == room.client.accessToken;

  /// Тот же app на новом месте или пути — с новым поколением: контент
  /// пересоздаётся (другой движок или новый deep-link).
  MiniAppInstance moved({String? appStartPath, bool? detached}) {
    interactiveState.invalidate();
    return MiniAppInstance(
      appUrl: appUrl,
      appId: appId,
      appName: appName,
      room: room,
      appType: appType,
      appStartPath: appStartPath ?? this.appStartPath,
      startParam: startParam,
      botMxid: botMxid,
      joinRequestQueryId: joinRequestQueryId,
      generation: generation + 1,
      detached: detached ?? this.detached,
      kind: kind,
      pageEvent: pageEvent,
    );
  }
}

/// Глобальный менеджер открытых MiniApp.
///
/// Хранит список открытых приложений, активное приложение,
/// состояние развёрнутости. Уведомляет подписчиков (MiniAppOverlay)
/// о любых изменениях.
///
/// [apps], [hasApps], [activeApp] — про то, что показано В ОКНЕ
/// Лизы (панель). Открепленные в окна ОС — в [detachedApps], их окнами
/// управляет `MiniAppWindows`.
class MiniAppManager extends ChangeNotifier {
  MiniAppManager._();
  static final MiniAppManager instance = MiniAppManager._();

  /// Скрытый IndexedStack остаётся mounted; видимость отдельно от сессии.
  bool isInteractiveVisible(MiniAppInstance app) =>
      app.sessionCurrent &&
      _apps.contains(app) &&
      (app.detached ? app.interactiveState.visible : _activeAppId == app.appId);

  @override
  void notifyListeners() {
    for (final app in _apps.where((app) => !app.detached)) {
      app.interactiveState.setVisible(_activeAppId == app.appId);
    }
    if (!hasApps) panelFilled.value = false;
    if (activeApp?.kind != MiniAppKind.html) chatListExpanded.value = false;
    super.notifyListeners();
  }

  final List<MiniAppInstance> _apps = [];
  String? _activeAppId;

  /// Ширина боковой панели на широком окне. ValueNotifier, а не поле с
  /// notifyListeners: при перетаскивании границы перестраивается только
  /// геометрия, а не весь overlay со всеми WebView.
  final panelWidth = ValueNotifier<double>(kMiniAppDefaultPanelWidth);

  /// Панель растянута на всё окно, кроме колонки пространств: бегунок
  /// утянули за середину окна. Живёт, пока открыта хоть одна панель.
  final panelFilled = ValueNotifier<bool>(false);

  /// Тянут границу боковой панели. На это время WebView прячется: нативный
  /// вид (WKWebView на macOS) лежит поверх Flutter и забирает отпускание
  /// кнопки мыши — Flutter его не видит, и граница залипает.
  final panelResizing = ValueNotifier<bool>(false);

  /// Список чатов свёрнут до аватарок, пока открыта HTML-страница; владелец
  /// развернул его вручную — true до закрытия страницы (тогда сбрасывается).
  final chatListExpanded = ValueNotifier<bool>(false);

  /// Список чатов можно свернуть: его публикует ChatList (открыт чат, нет
  /// поиска и пространства). Только тогда страница сворачивает список.
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

  void expandChatList() => chatListExpanded.value = true;
  void collapseChatList() => chatListExpanded.value = false;

  /// Хост сейчас раскладывает панель сбоку от чата (широкое окно). Выставляет
  /// MiniAppOverlay при построении — карточка страницы по нему решает,
  /// открывать ли её сама.
  bool sideLayout = false;

  final Set<String> _autoOpenedPages = {};

  /// Страницу этого события ещё не открывали автоматически. Помечает как
  /// открытую: закрыл вручную — повторно сама не вылезет.
  bool claimAutoOpen(String eventId) => _autoOpenedPages.add(eventId);

  /// Ход сборки страницы, которую сейчас ждёт панель «собираю» (null — не ждёт).
  final pageBuild = ValueNotifier<FluidPagePending?>(null);

  /// Обещания, панель которых пользователь закрыл: их страница сама не
  /// откроется (тапом по карточке — да).
  final Set<String> _dismissedPending = {};

  static String pendingUrl(String pendingId) => 'pending:$pendingId';

  /// Панель «собираю страницу» справа — сразу по обещанию бота; страница,
  /// когда придёт, встанет на её место (тот же [kFluidPageAppId]).
  void openPendingPage(
    Room room,
    FluidPagePending pending, {
    required String title,
  }) {
    pageBuild.value = pending;
    open(
      appUrl: pendingUrl(pending.id),
      appId: kFluidPageAppId,
      appName: title,
      room: room,
      allowDetach: false,
      kind: MiniAppKind.html,
    );
  }

  /// Новый этап сборки — только для того обещания, которое ждёт панель.
  void updatePending(FluidPagePending pending) {
    if (pageBuild.value?.id == pending.id) pageBuild.value = pending;
  }

  bool showsPending(String pendingId) => _apps.any(
    (a) => a.appId == kFluidPageAppId && a.appUrl == pendingUrl(pendingId),
  );

  bool isPendingDismissed(String pendingId) =>
      _dismissedPending.contains(pendingId);

  /// Открыть HTML-страницу из события [event] панелью (не окном ОС: страница
  /// живёт рядом с чатом, чтобы с ботом можно было продолжать переписку).
  void openPage(Event event, {required String title}) => open(
    appUrl: event.eventId,
    appId: kFluidPageAppId,
    appName: title,
    room: event.room,
    allowDetach: false,
    kind: MiniAppKind.html,
    pageEvent: event,
  );

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
    String startParam = '',
    String? botMxid,
    String? joinRequestQueryId,
    bool allowDetach = true,
    MiniAppKind kind = MiniAppKind.miniApp,
    Event? pageEvent,
  }) {
    final index = _apps.indexWhere((a) => a.appId == appId);
    if (index >= 0) {
      final existing = _apps[index];
      if ((appStartPath.isNotEmpty && appStartPath != existing.appStartPath) ||
          startParam != existing.startParam ||
          botMxid != existing.botMxid ||
          joinRequestQueryId != existing.joinRequestQueryId ||
          !existing.sessionCurrent ||
          appType != existing.appType ||
          !identical(room.client, existing.room.client) ||
          room.id != existing.room.id ||
          appUrl != existing.appUrl ||
          kind != existing.kind) {
        existing.interactiveState.invalidate();
        _apps[index] = MiniAppInstance(
          appUrl: appUrl,
          appId: appId,
          appName: appName,
          room: room,
          appType: appType,
          appStartPath: appStartPath.isEmpty
              ? existing.appStartPath
              : appStartPath,
          startParam: startParam,
          botMxid: botMxid,
          joinRequestQueryId: joinRequestQueryId,
          generation: existing.generation + 1,
          detached: existing.detached,
          kind: kind,
          pageEvent: pageEvent,
        );
      }
      if (existing.detached) {
        _focusRequests.add(appId);
      } else {
        _activeAppId = appId;
      }
      notifyListeners();
      return;
    }

    final detached = windowsSupported && allowDetach;
    _apps.add(
      MiniAppInstance(
        appUrl: appUrl,
        appId: appId,
        appName: appName,
        room: room,
        appType: appType,
        appStartPath: appStartPath,
        startParam: startParam,
        botMxid: botMxid,
        joinRequestQueryId: joinRequestQueryId,
        detached: detached,
        kind: kind,
        pageEvent: pageEvent,
      ),
    );
    if (!detached) _activeAppId = appId;
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
    _apps[index] = _apps[index].moved(appStartPath: startPath, detached: false);
    _activeAppId = appId;
    notifyListeners();
  }

  /// Активный в панели ушёл (закрыт/откреплён) — активным становится последний
  /// оставшийся в панели.
  void _pickDockedActive() {
    if (activeApp != null) return;
    _activeAppId = _docked.lastOrNull?.appId;
  }

  /// Закрывает конкретный miniApp.
  void close(String appId) {
    for (final app in _apps.where((a) => a.appId == appId)) {
      app.interactiveState.invalidate();
      if (app.kind == MiniAppKind.html && app.pageEvent == null) {
        _dismissedPending.add(app.appUrl.substring('pending:'.length));
      }
    }
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

  /// Закрывает все miniApp.
  void closeAll() {
    for (final app in _apps) {
      app.interactiveState.invalidate();
    }
    _apps.clear();
    _activeAppId = null;
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
