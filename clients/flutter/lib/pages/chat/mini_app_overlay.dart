import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/fluid_page_view.dart';
import 'package:liza/pages/chat/mini_app_host_api.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/pages/chat/mini_app_window.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_expanded_view.dart';
import 'package:liza/utils/adaptive_orientation.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/layouts/mini_app_host_scope.dart';

/// Минимальная ширина боковой панели miniApp.
const double kMiniAppMinPanelWidth = 320;

/// Как сейчас показан открытый miniApp.
enum MiniAppLayoutMode {
  /// Лист на весь экран (узкое окно и планшет).
  sheet,

  /// Боковая панель справа от приложения (широкое окно).
  side,
}

/// Сколько ширины боковая панель оставляет приложению в окне уже порога
/// колонок: там приложение показывает одну колонку (список ИЛИ чат), как на
/// телефоне.
const double kMiniAppMinNarrowChildWidth = 360;

/// С какой ширины окна возможна боковая панель: минимальная панель + узкое
/// приложение. Уже — лист на весь экран.
const double kMiniAppSideMinWindowWidth =
    kMiniAppMinPanelWidth + kMiniAppMinNarrowChildWidth;

/// Окно достаточно широкое, чтобы рядом с панелью приложение сохраняло две
/// колонки. Уже — приложение рядом с панелью живёт в одну колонку и панель не
/// даёт ему расшириться до порога колонок (иначе раскладка сменилась бы
/// посреди перетаскивания границы).
bool miniAppKeepsColumnsFor(double windowWidth) =>
    windowWidth >= kMiniAppDockedByDefaultMinWidth;

/// Режим раскладки для окна шириной [windowWidth]: боковая панель — пока в окне
/// помещаются минимальная панель и узкое приложение, и это не планшет.
MiniAppLayoutMode miniAppLayoutModeFor(
  double windowWidth, {
  bool tablet = false,
}) => tablet || windowWidth < kMiniAppSideMinWindowWidth
    ? MiniAppLayoutMode.sheet
    : MiniAppLayoutMode.side;

/// Ширина закреплённой боковой панели, ужатая под текущее окно. В широком окне
/// приложению слева остаётся не меньше порога двух колонок; в узком — не меньше
/// [kMiniAppMinNarrowChildWidth], и оно никогда не шире порога колонок.
double clampMiniAppPanelWidth(double width, double windowWidth) {
  if (miniAppKeepsColumnsFor(windowWidth)) {
    return width.clamp(
      kMiniAppMinPanelWidth,
      math.max(kMiniAppMinPanelWidth, windowWidth - kMiniAppMinChildWidth),
    );
  }
  final min = math.max(
    kMiniAppMinPanelWidth,
    windowWidth - (kMiniAppMinChildWidth - 1),
  );
  final max = math.max(min, windowWidth - kMiniAppMinNarrowChildWidth);
  return width.clamp(min, max);
}

/// Глобальный хост miniApp — оборачивает child (Router) и раскладывает рядом
/// с ним окно miniApp.
///
/// Встраивается в LizaApp.builder, чтобы miniApp жил поверх навигации.
///
/// Дерево не меняет форму при смене режима: child и панель всегда лежат в
/// одном Stack под постоянными ключами, меняется только геометрия Positioned.
/// Иначе Router терял бы стек навигации, а WebView — страницу (корзину, оплату).
class MiniAppOverlay extends StatefulWidget {
  final Widget child;

  const MiniAppOverlay({required this.child, super.key});

  /// Подмена содержимого miniApp в widget-тестах: WebView там не поднимается.
  @visibleForTesting
  static Widget Function(BuildContext context, MiniAppInstance app)?
  debugContentBuilder;

  /// Планшет ли это (раскладка «как на ПК»). Порог тот же, что у политики
  /// ориентаций. Подменяется в тестах: там платформа — хост разработчика.
  static bool Function(Size size) isTablet = (size) =>
      PlatformInfos.isMobile && size.shortestSide >= kTabletShortestSide;

  @override
  State<MiniAppOverlay> createState() => _MiniAppOverlayState();
}

class _MiniAppOverlayState extends State<MiniAppOverlay>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _manager = MiniAppManager.instance;
  final _panelNavigatorKey = GlobalKey<NavigatorState>();

  late final AnimationController _slideController;

  final _panelKey = GlobalKey();

  // Drag offset для свайпа листа вниз
  double _dragOffset = 0;
  static const _closeMinDistance = 150.0;
  static const _closeSheetFraction = 0.25;
  static const _closeMinFlingDistance = 60.0;
  static const _velocityThreshold = 200.0;

  // Тянут границу боковой панели — поверх WebView кладём щит, а сам WebView
  // прячем (panelResizing): щит Flutter нативный вид не перекрывает, и
  // отпускание мыши над страницей уходило в WebView — граница «залипала».
  bool get _resizing => _manager.panelResizing.value;
  set _resizing(bool value) => _manager.panelResizing.value = value;
  double _resizeStartLeft = 0;
  double _resizeDownX = 0;
  double _resizeWindowWidth = 0;
  double _resizePinnedWidth = 0;
  double? _filledMinX;
  bool _restoreLocked = false;
  int? _resizePointer;
  int? _resizeDevice;
  String? _resizeContentKey;
  bool _globalRouteAdded = false;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onManagerChanged);
    // Наблюдатель регистрируется раньше Router (хост — его предок), поэтому
    // системное «назад» сначала приходит сюда.
    WidgetsBinding.instance.addObserver(this);

    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    if (_manager.hasApps) _slideController.value = 1;
  }

  @override
  void dispose() {
    _onResizeEnd(notify: false);
    WidgetsBinding.instance.removeObserver(this);
    _manager.removeListener(_onManagerChanged);
    _slideController.dispose();
    super.dispose();
  }

  /// Android «назад»: Navigator панели не подключён к роутеру, поэтому сначала
  /// закрываем его диалог/лист (подтверждение оплаты и т.п.), затем
  /// возвращаем панель «на всё окно» к закреплённой, а лист закрываем.
  /// Панель рядом с чатом «назад» не трогает — он уходит чату.
  @override
  Future<bool> didPopRoute() async {
    if (!_manager.hasApps) return false;
    // Back меняет навигацию/геометрию вне pointer-жеста. Завершаем session
    // до await: это нужно и когда maybePop закроет только диалог панели.
    _onResizeEnd();
    final active = _manager.activeApp;
    final navigator = _panelNavigatorKey.currentState;
    if (navigator != null && await navigator.maybePop()) return true;
    if (!mounted) return false;
    final size = MediaQuery.sizeOf(context);
    final mode = miniAppLayoutModeFor(
      size.width,
      tablet: MiniAppOverlay.isTablet(size),
    );
    if (mode == MiniAppLayoutMode.side) {
      if (!_manager.panelFilled.value) return false;
      _manager.panelFilled.value = false;
      return true;
    }
    if (active != null) _manager.close(active.appId);
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _onResizeEnd();
  }

  void _onManagerChanged() {
    if (!_manager.hasApps ||
        _manager.activeApp?.contentKey != _resizeContentKey) {
      _onResizeEnd();
    }
    if (!_manager.hasApps) {
      // Панель уже убрана из дерева — без анимации, иначе приложение ещё
      // 300 мс сжато рядом с пустым местом.
      _slideController.value = 0;
    } else {
      _slideController.forward();
    }
    setState(() {});
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffset = (_dragOffset + details.delta.dy).clamp(
        0.0,
        double.infinity,
      );
    });
  }

  /// Свайп листа вниз закрывает активный miniApp: далеко утянули либо быстро
  /// смахнули (но не случайным касанием).
  Future<void> _onDragEnd(DragEndDetails details) async {
    final sheetHeight = MediaQuery.sizeOf(context).height;
    final far =
        _dragOffset >
        math.max(_closeMinDistance, sheetHeight * _closeSheetFraction);
    final fling =
        details.velocity.pixelsPerSecond.dy > _velocityThreshold &&
        _dragOffset > _closeMinFlingDistance;
    final active = _manager.activeApp;
    if (active == null || !(far || fling)) {
      setState(() => _dragOffset = 0);
      return;
    }
    await _slideController.reverse();
    if (!mounted) return;
    setState(() => _dragOffset = 0);
    _manager.close(active.appId);
  }

  double _panelLeft(double windowWidth) => _manager.panelFilled.value
      ? (miniAppKeepsColumnsFor(windowWidth) ? LizaThemes.navRailWidth : 0)
      : windowWidth -
            clampMiniAppPanelWidth(_manager.panelWidth.value, windowWidth);

  // Снимок берём именно на down: распознаватель drag добавил бы slop к
  // порогу возврата и потерял первые изменения исходной pinned-ширины.
  void _onResizeStart(PointerDownEvent event, double windowWidth) {
    if (_resizePointer != null || event.buttons != kPrimaryButton) return;
    _resizePointer = event.pointer;
    _resizeDevice = event.device;
    _resizeContentKey = _manager.activeApp?.contentKey;
    _resizeStartLeft = _panelLeft(windowWidth);
    _resizeDownX = event.position.dx;
    _resizeWindowWidth = windowWidth;
    _resizePinnedWidth = _manager.panelWidth.value;
    _filledMinX = _manager.panelFilled.value ? event.position.dx : null;
    _restoreLocked = false;
    if (!_globalRouteAdded) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
      _globalRouteAdded = true;
    }
    setState(() => _resizing = true);
  }

  void _onGlobalPointer(PointerEvent event) {
    if (_resizePointer == null) return;
    // Hover от того же устройства восстанавливает потерянный native up.
    // Pointer id у hover может отличаться; чужая мышь/палец session не завершает.
    if (event is PointerHoverEvent && event.device == _resizeDevice) {
      _onResizeEnd();
      return;
    }
    if (event.pointer != _resizePointer) return;
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _onResizeEnd();
    } else if (event is PointerMoveEvent) {
      _onResize(event.position.dx);
    }
  }

  void _removeGlobalRoute() {
    if (!_globalRouteAdded) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _globalRouteAdded = false;
  }

  void _onResize(double pointerX) {
    if (_restoreLocked) return;
    final windowWidth = _resizeWindowWidth;
    if (_manager.panelFilled.value) {
      final minX = math.min(_filledMinX ?? pointerX, pointerX);
      _filledMinX = minX;
      if (pointerX - minX + 1e-8 >= windowWidth * .05) {
        _restoreLocked = true;
        _manager.panelWidth.value = clampMiniAppPanelWidth(
          _resizePinnedWidth,
          windowWidth,
        );
        _manager.panelFilled.value = false;
      }
      return;
    }
    final left = _resizeStartLeft + pointerX - _resizeDownX;
    if (left < windowWidth / 2) {
      // Сохраняем исходную ширину и для следующего, отдельного filled-жеста.
      _manager.panelWidth.value = _resizePinnedWidth;
      _filledMinX = pointerX;
      _manager.panelFilled.value = true;
    } else {
      _manager.panelWidth.value = clampMiniAppPanelWidth(
        windowWidth - left,
        windowWidth,
      );
    }
  }

  void _onResizeEnd({bool notify = true}) {
    _removeGlobalRoute();
    _resizePointer = null;
    _resizeDevice = null;
    _resizeContentKey = null;
    _filledMinX = null;
    _restoreLocked = false;
    if (!_resizing) return;
    if (notify && mounted) {
      setState(() => _resizing = false);
    } else {
      _resizing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final hasApps = _manager.hasApps;
    final wide = LizaThemes.isColumnModeByWidth(size.width);
    final tablet = MiniAppOverlay.isTablet(size);
    final mode = miniAppLayoutModeFor(size.width, tablet: tablet);
    // Свежий снимок темы — для отдельных окон ОС, которые откроются потом.
    MiniAppWindows.instance.theme = Theme.of(context);
    // Режим сменился посреди перетаскивания границы (поворот, ширина окна) —
    // ручка размонтирована и onEnd не придёт: не оставляем висеть щит.
    if (_resizing &&
        (mode == MiniAppLayoutMode.sheet || size.width != _resizeWindowWidth)) {
      final pointer = _resizePointer;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_resizePointer == pointer) _onResizeEnd();
      });
    }

    final panel = hasApps
        ? KeyedSubtree(
            key: _panelKey,
            child: Material(
              elevation: 16,
              borderRadius: mode == MiniAppLayoutMode.sheet && !wide
                  ? const BorderRadius.vertical(top: Radius.circular(14))
                  : BorderRadius.zero,
              clipBehavior: Clip.antiAlias,
              color: Theme.of(context).colorScheme.surface,
              // Свой Navigator: хост смонтирован НАД Router, и без него
              // showDialog/PopupMenuButton/Tooltip из miniApp падают
              // («context does not include a Navigator»).
              // HeroControllerScope.none: MaterialApp отдаёт свой
              // HeroController Navigator'у роутера, второй Navigator с тем же
              // контроллером падает («can not be shared by multiple»).
              child: HeroControllerScope.none(
                child: Navigator(
                  key: _panelNavigatorKey,
                  onGenerateRoute: (_) => PageRouteBuilder<void>(
                    pageBuilder: (_, _, _) => const _MiniAppPanelBody(),
                    transitionDuration: Duration.zero,
                  ),
                ),
              ),
            ),
          )
        : null;

    return AnimatedBuilder(
      animation: Listenable.merge([
        _slideController,
        _manager.panelWidth,
        _manager.panelFilled,
        _manager.chatListCompactable,
        _manager.chatListExpanded,
      ]),
      builder: (context, _) {
        final t = _slideController.value;
        var childMq = mq;
        var childRect = Rect.fromLTWH(0, 0, size.width, size.height);
        final Rect panelRect;
        var panelMq = mq;
        Rect? dividerRect;
        switch (mode) {
          case MiniAppLayoutMode.side:
            final pw = clampMiniAppPanelWidth(
              _manager.panelWidth.value,
              size.width,
            );
            // Панель выезжает снизу и уезжает вниз — туда, где появляется
            // свёрнутая плашка (а не вбок, где её потом не найти). Приложение
            // при этом плавно занимает освободившуюся ширину под панелью.
            // На всё окно панель лишь ложится поверх приложения: оно остаётся
            // на ширине закреплённой панели и не перестраивается.
            childRect = Rect.fromLTWH(0, 0, size.width - pw * t, size.height);
            childMq = mq.copyWith(size: childRect.size);
            final left = _panelLeft(size.width);
            panelRect = Rect.fromLTWH(
              left,
              size.height * (1 - t),
              size.width - left,
              size.height,
            );
            panelMq = mq.copyWith(size: panelRect.size);
            if (t == 1) {
              dividerRect = Rect.fromLTWH(
                left == 0 ? 0 : left - 12,
                0,
                24,
                size.height,
              );
            }
          case MiniAppLayoutMode.sheet:
            // Лист стартует сразу под статус-баром — без лишнего зазора
            // сверху, чтобы интерфейс магазина занимал максимум высоты.
            final sheetTop = mq.padding.top;
            final height = (size.height - sheetTop - _dragOffset).clamp(
              0.0,
              size.height,
            );
            panelRect = Rect.fromLTWH(
              0,
              sheetTop + _dragOffset + (size.height - sheetTop) * (1 - t),
              size.width,
              height,
            );
        }

        return Stack(
          children: [
            Positioned.fromRect(
              key: const ValueKey('miniapp-host-child'),
              rect: childRect,
              child: MediaQuery(
                data: childMq,
                child: MiniAppHostScope(
                  forceColumnMode:
                      mode == MiniAppLayoutMode.side &&
                      miniAppKeepsColumnsFor(size.width),
                  // Открытая HTML-страница забирает ширину у списка чатов: он
                  // сжимается до аватарок, пока страница не закрыта.
                  compactChatList:
                      mode == MiniAppLayoutMode.side &&
                      miniAppKeepsColumnsFor(size.width) &&
                      (_manager.activeApp?.isPageLike ?? false) &&
                      _manager.chatListCompactable.value &&
                      !_manager.chatListExpanded.value,
                  child: widget.child,
                ),
              ),
            ),
            if (panel != null)
              Positioned.fromRect(
                key: const ValueKey('miniapp-host-panel'),
                rect: panelRect,
                child: Offstage(
                  offstage: t == 0,
                  child: MediaQuery(
                    data: panelMq,
                    // Одинаковая обёртка во всех режимах (меняются только
                    // параметры) — WebView не переподвешивается.
                    child: _MiniAppLayoutScope(
                      mode: mode,
                      wide: wide,
                      contentInset: mode == MiniAppLayoutMode.sheet
                          ? 0
                          : panelRect.left == 0
                          ? 24
                          : 12,
                      onDragUpdate: _onDragUpdate,
                      onDragEnd: _onDragEnd,
                      child: panel,
                    ),
                  ),
                ),
              ),
            if (_resizing)
              Positioned.fromRect(
                key: const ValueKey('miniapp-host-shield'),
                rect: Offset.zero & size,
                child: const MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: SizedBox.expand(),
                ),
              ),
            if (dividerRect != null)
              Positioned.fromRect(
                key: const ValueKey('miniapp-host-divider'),
                rect: dividerRect,
                child: _PanelResizeHandle(
                  onDown: (event) => _onResizeStart(event, size.width),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Режим раскладки для шапки панели. Живёт НАД Navigator панели: страница
/// внутри маршрута строится один раз, а зависимость от InheritedWidget
/// перестраивает её при смене режима.
class _MiniAppLayoutScope extends InheritedWidget {
  final MiniAppLayoutMode mode;
  final bool wide;
  final double contentInset;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  const _MiniAppLayoutScope({
    required this.mode,
    required this.wide,
    required this.contentInset,
    required this.onDragUpdate,
    required this.onDragEnd,
    required super.child,
  });

  static _MiniAppLayoutScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MiniAppLayoutScope>()!;

  @override
  bool updateShouldNotify(_MiniAppLayoutScope oldWidget) =>
      mode != oldWidget.mode ||
      wide != oldWidget.wide ||
      contentInset != oldWidget.contentInset;
}

/// Содержимое панели: шапка + WebView всех открытых miniApp + локальный тост.
class _MiniAppPanelBody extends StatefulWidget {
  const _MiniAppPanelBody();

  @override
  State<_MiniAppPanelBody> createState() => _MiniAppPanelBodyState();
}

class _MiniAppPanelBodyState extends State<_MiniAppPanelBody> {
  final _manager = MiniAppManager.instance;

  // Ключи для сохранения состояния WebView каждого miniApp
  final Map<String, GlobalKey> _contentKeys = {};

  // Локальный тост поверх панели: ScaffoldMessenger тут бесполезен — хост
  // смонтирован в LizaApp.builder ПОВЕРХ Router, и корневой SnackBar рисуется
  // ПОД панелью.
  String? _toast;
  int _toastGen = 0;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onManagerChanged);
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerChanged);
    super.dispose();
  }

  void _onManagerChanged() => setState(() {});

  void _showToast(String message, {bool autoHide = true}) {
    final gen = ++_toastGen;
    setState(() => _toast = message);
    if (autoHide) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _toastGen == gen) setState(() => _toast = null);
      });
    }
  }

  /// Открепить активный app в отдельное окно ОС — на той же странице.
  Future<void> _detachActiveApp() async {
    final app = _manager.activeApp;
    if (app == null) return;
    final state = _contentKeys[app.contentKey]?.currentState;
    if (state is MiniAppWebViewContentState && state.paymentInProgress) {
      _showToast(L10n.of(context).miniAppMoveDuringPayment);
      return;
    }
    final startPath = state is MiniAppWebViewContentState
        ? await state.currentStartPath()
        : null;
    if (!mounted || _manager.activeApp != app) return;
    _manager.detach(app.appId, startPath: startPath);
  }

  GlobalKey _keyFor(MiniAppInstance app) {
    return _contentKeys.putIfAbsent(
      app.contentKey,
      () => app.isPageLike
          ? GlobalKey()
          : GlobalKey<MiniAppWebViewContentState>(),
    );
  }

  void _cleanupKeys() {
    final activeKeys = _manager.apps.map((a) => a.contentKey).toSet();
    _contentKeys.removeWhere((key, _) => !activeKeys.contains(key));
  }

  @override
  Widget build(BuildContext context) {
    _cleanupKeys();
    final scope = _MiniAppLayoutScope.of(context);
    return Stack(
      children: [
        Column(
          children: [
            _MiniAppHeader(
              app: _manager.activeApp,
              manager: _manager,
              mode: scope.mode,
              wide: scope.wide,
              onDragUpdate: scope.onDragUpdate,
              onDragEnd: scope.onDragEnd,
              onDetach:
                  miniAppDetachAllowed(context) &&
                      _manager.activeApp?.kind == MiniAppKind.miniApp
                  ? _detachActiveApp
                  : null,
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: scope.contentInset),
                child: _buildContentStack(),
              ),
            ),
          ],
        ),
        if (_toast != null)
          Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: MiniAppToast(text: _toast!),
          ),
      ],
    );
  }

  Widget _buildContentStack() {
    final apps = _manager.apps;
    final activeId = _manager.activeAppId;
    final activeIndex = apps.indexWhere((a) => a.appId == activeId);

    if (apps.isEmpty) return const SizedBox.shrink();

    final debugBuilder = MiniAppOverlay.debugContentBuilder;
    final stack = IndexedStack(
      index: activeIndex >= 0 ? activeIndex : 0,
      children: [
        for (final app in apps)
          debugBuilder != null
              ? KeyedSubtree(
                  key: _keyFor(app),
                  child: debugBuilder(context, app),
                )
              : app.kind == MiniAppKind.widget
              ? TgWidgetExpandedView(
                  key: _keyFor(app),
                  event: app.widgetEvent!,
                  timeline: app.widgetTimeline,
                  title: app.appName,
                )
              : app.kind == MiniAppKind.html
              ? FluidPageView(
                  key: _keyFor(app),
                  pageKey: app.contentKey,
                  loadDocument: () => loadFluidPageDocument(app.pageEvent!),
                )
              : MiniAppWebViewContent(
                  key: _keyFor(app),
                  appUrl: app.appUrl,
                  appId: app.appId,
                  appName: app.appName,
                  host: RoomMiniAppHostApi(
                    room: app.room,
                    appId: app.appId,
                    appUrl: app.appUrl,
                    startParam: app.startParam,
                    botMxid: app.botMxid,
                    joinRequestQueryId: app.joinRequestQueryId,
                    interactiveSessionId: app.interactiveSessionId,
                    interactiveState: app.interactiveState,
                    isCurrent: () =>
                        app.sessionCurrent && _manager.apps.contains(app),
                    isInteractiveCurrent: () =>
                        _manager.isInteractiveVisible(app),
                  ),
                  roomId: app.room.id,
                  appType: app.appType,
                  appStartPath: app.appStartPath,
                  onClose: () => _manager.close(app.appId),
                ),
      ],
    );
    // Offstage, а не удаление: WebView остаётся живым (страница, корзина),
    // просто не рисуется, пока тянут границу.
    return ValueListenableBuilder<bool>(
      valueListenable: _manager.panelResizing,
      child: stack,
      builder: (context, resizing, stack) => Stack(
        fit: StackFit.expand,
        children: [
          Offstage(offstage: resizing, child: stack),
          if (resizing)
            ColoredBox(
              key: const ValueKey('miniapp-resize-placeholder'),
              color: Theme.of(context).colorScheme.surfaceContainerLow,
            ),
        ],
      ),
    );
  }
}

/// Граница боковой панели — тянется мышью.
class _PanelResizeHandle extends StatelessWidget {
  final PointerDownEventListener onDown;

  const _PanelResizeHandle({required this.onDown});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: onDown,
        child: Semantics(
          label: L10n.of(context).miniAppResizePanel,
          child: Center(
            child: Container(
              key: const ValueKey('miniapp-resize-pill'),
              width: 4,
              height: 40,
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Header открытого miniApp: название, «Открепить» и крайний справа крестик.
class _MiniAppHeader extends StatelessWidget {
  final MiniAppInstance? app;
  final MiniAppManager manager;
  final MiniAppLayoutMode mode;
  final bool wide;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  /// «Открепить в отдельное окно». null — окна ОС не поддержаны.
  final VoidCallback? onDetach;

  const _MiniAppHeader({
    required this.app,
    required this.manager,
    required this.mode,
    required this.wide,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.onDetach,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final appName = app?.appName ?? '';
    // Свайп вниз закрывает только мобильный лист.
    final draggable = mode == MiniAppLayoutMode.sheet && !wide;

    return GestureDetector(
      onVerticalDragUpdate: draggable ? onDragUpdate : null,
      onVerticalDragEnd: draggable ? onDragEnd : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: colorScheme.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (draggable)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurface.withAlpha(60),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      appName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.start,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (app?.isPageLike == true && mode == MiniAppLayoutMode.side)
                    ValueListenableBuilder<bool>(
                      valueListenable: manager.chatListExpanded,
                      builder: (context, expanded, _) => IconButton(
                        key: const ValueKey('fluid-page-chatlist-toggle'),
                        tooltip: expanded
                            ? L10n.of(context).chatListCollapse
                            : L10n.of(context).chatListExpand,
                        icon: Icon(
                          expanded
                              ? Icons.keyboard_double_arrow_left
                              : Icons.keyboard_double_arrow_right,
                          size: 20,
                        ),
                        onPressed: expanded
                            ? manager.collapseChatList
                            : manager.expandChatList,
                      ),
                    ),
                  if (onDetach != null)
                    IconButton(
                      key: const ValueKey('miniapp-detach'),
                      tooltip: L10n.of(context).miniAppDetach,
                      icon: const Icon(Icons.open_in_new, size: 20),
                      onPressed: onDetach,
                    ),
                  IconButton(
                    key: const ValueKey('miniapp-close'),
                    tooltip: L10n.of(context).close,
                    icon: const Icon(Icons.close, size: 22),
                    onPressed: () {
                      if (app != null) manager.close(app!.appId);
                    },
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            Divider(height: 1, color: colorScheme.outlineVariant),
          ],
        ),
      ),
    );
  }
}

/// Локальный тост поверх панели mini App (вместо ScaffoldMessenger, который тут
/// уходит под панель). Авто-скрытие — на стороне панели.
class MiniAppToast extends StatelessWidget {
  final String text;

  const MiniAppToast({required this.text, super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Center(
        child: Material(
          color: colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onInverseSurface,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
