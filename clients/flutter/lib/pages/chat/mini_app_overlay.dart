import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_host_api.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/pages/chat/mini_app_window.dart';
import 'package:liza/pages/chat_list/compact_chat_list_column.dart';
import 'package:liza/utils/adaptive_orientation.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/layouts/mini_app_host_scope.dart';
import 'package:liza/widgets/liza_app.dart';

/// Высота контента свёрнутой плашки (без bottom safe-area).
///
/// Эту же величину чат резервирует снизу под полем ввода
/// ([ChatInputRow]), чтобы плашка не перекрывала инпут.
const double kMiniAppCollapsedBarHeight = 40;

/// Минимальная ширина боковой панели miniApp.
const double kMiniAppMinPanelWidth = 320;

/// С какой ширины окна возможна боковая панель; уже — двойной экран.
const double kMiniAppSideMinWindowWidth =
    kMiniAppMinChildWidth + kMiniAppMinPanelWidth;

/// Сколько ширины панель оставляет приложению, когда список чатов свёрнут до
/// аватарок: rail + колонка аватарок + разделители + чат ≥360.
const double kMiniAppCompactMinChildWidth =
    LizaThemes.navRailWidth + kCompactChatListWidth + 2 + 360;

/// Список сворачивается, когда приложение уже порога двух колонок на это
/// число, а разворачивается — на пороге. Без зазора колонка мигает, пока
/// курсор стоит на границе.
const double _kCompactHysteresis = 24;

/// Сколько высоты двойной экран оставляет чату над клавиатурой.
const double _kSplitMinChatHeight = 160;

/// Минимальная высота miniApp в двойном экране (шапка + полоска контента).
const double kMiniAppSplitMinPanelHeight = 150;

/// Зона касания бегунка двойного экрана. Полосы нет — на стыке только пилюля,
/// а зона прозрачна для тапов: тап доходит до заголовка чата, перехватывается
/// лишь вертикальное перетаскивание.
const double kMiniAppSplitHandleWidth = 88;
const double kMiniAppSplitHandleHeight = 32;

/// Сколько зоны бегунка лежит над стыком. Над WebView касание ненадёжно
/// (iframe на Web, platform view на мобилках), поэтому зона смещена на чат и
/// не достаёт до MainButton miniApp (его низ — 8 px над стыком).
const double kMiniAppSplitHandleAbove = 6;

/// Доля, с которой отпущенный бегунок переводит miniApp на весь экран.
const double kMiniAppSplitFullscreenSnap = 0.9;

/// Как сейчас показан развёрнутый miniApp.
enum MiniAppLayoutMode {
  /// Лист на весь экран (узкое окно) или панель поверх всего приложения
  /// (широкое окно, «на весь экран»).
  sheet,

  /// Боковая панель справа от приложения (широкое окно).
  side,

  /// Двойной экран: miniApp сверху, приложение снизу (узкое окно).
  split,
}

/// Режим раскладки для окна шириной [windowWidth].
///
/// [tablet]: планшет по умолчанию на весь экран, закрепляется только сбоку —
/// половинчатого экрана по вертикали, как на телефоне, у него нет.
MiniAppLayoutMode miniAppLayoutModeFor(
  MiniAppManager manager,
  double windowWidth, {
  bool tablet = false,
}) {
  if (manager.isFullscreenFor(windowWidth, tablet: tablet)) {
    return MiniAppLayoutMode.sheet;
  }
  if (windowWidth >= kMiniAppSideMinWindowWidth) return MiniAppLayoutMode.side;
  return tablet ? MiniAppLayoutMode.sheet : MiniAppLayoutMode.split;
}

/// Ширина боковой панели, ужатая под текущее окно. [compactable] — список
/// чатов можно свернуть до аватарок, и панель тянется дальше порога двух
/// колонок.
double clampMiniAppPanelWidth(
  double width,
  double windowWidth, {
  bool compactable = false,
}) => width.clamp(
  kMiniAppMinPanelWidth,
  math.max(
    kMiniAppMinPanelWidth,
    windowWidth -
        (compactable ? kMiniAppCompactMinChildWidth : kMiniAppMinChildWidth),
  ),
);

/// Глобальный хост miniApp — оборачивает child (Router) и раскладывает рядом
/// с ним развёрнутое окно miniApp либо свёрнутую плашку.
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
  static const _minimizeThreshold = 150.0;
  static const _velocityThreshold = 200.0;

  // Тянут границу боковой панели — поверх WebView кладём щит, иначе
  // platform view / iframe перехватывает мышь, и граница «залипает».
  bool _resizing = false;
  double _resizeStartWidth = 0;
  double _resizeDx = 0;

  // Список чатов свёрнут до аватарок (с гистерезисом — см. _updateCompact).
  bool _compact = false;

  // Бегунок двойного экрана: пока тянут, двигается только линия-превью —
  // ресайз platform view на каждый кадр дорог на iOS/Android.
  double? _splitPreview;
  double _splitDragStart = 0;
  double _splitDragDy = 0;

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
    if (_manager.hasApps && _manager.isExpanded) _slideController.value = 1;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _manager.removeListener(_onManagerChanged);
    _slideController.dispose();
    super.dispose();
  }

  /// Android «назад»: Navigator панели не подключён к роутеру, поэтому сначала
  /// закрываем его диалог/лист (подтверждение оплаты и т.п.), затем
  /// сворачиваем лист на весь экран. Панель рядом с чатом «назад» не трогает —
  /// он уходит чату.
  @override
  Future<bool> didPopRoute() async {
    if (!_manager.hasApps || !_manager.isExpanded) return false;
    final navigator = _panelNavigatorKey.currentState;
    if (navigator != null && await navigator.maybePop()) return true;
    if (!mounted) return false;
    final size = MediaQuery.sizeOf(context);
    final mode = miniAppLayoutModeFor(
      _manager,
      size.width,
      tablet: MiniAppOverlay.isTablet(size),
    );
    if (mode != MiniAppLayoutMode.sheet) {
      return false;
    }
    _manager.minimize();
    return true;
  }

  void _onManagerChanged() {
    if (!_manager.hasApps) {
      // Панель уже убрана из дерева — без анимации, иначе приложение ещё
      // 300 мс сжато рядом с пустым местом.
      _slideController.value = 0;
    } else if (_manager.isExpanded) {
      _slideController.forward();
    } else {
      _slideController.reverse();
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

  void _onDragEnd(DragEndDetails details) {
    if (_dragOffset > _minimizeThreshold ||
        details.velocity.pixelsPerSecond.dy > _velocityThreshold) {
      _manager.minimize();
    }
    setState(() => _dragOffset = 0);
  }

  // Ширину считаем от точки старта по суммарному смещению: тогда граница
  // не дёргается, когда курсор ушёл за предел и возвращается.
  bool get _compactable => _manager.chatListCompactable.value;

  void _onResizeStart(double windowWidth) {
    _resizeStartWidth = clampMiniAppPanelWidth(
      _manager.panelWidth.value,
      windowWidth,
      compactable: _compactable,
    );
    _resizeDx = 0;
    setState(() => _resizing = true);
  }

  void _onResize(double dx, double windowWidth) {
    _resizeDx += dx;
    _manager.panelWidth.value = clampMiniAppPanelWidth(
      _resizeStartWidth - _resizeDx,
      windowWidth,
      compactable: _compactable,
    );
  }

  void _updateCompact(bool compactable, double childWidth) {
    if (!compactable) {
      _compact = false;
    } else if (!_compact &&
        childWidth < kMiniAppMinChildWidth - _kCompactHysteresis) {
      _compact = true;
    } else if (_compact && childWidth >= kMiniAppMinChildWidth - 0.5) {
      _compact = false;
    }
  }

  double _splitMinFraction(double available) =>
      math.min(kMiniAppSplitMinPanelHeight / available, 0.5);

  /// Сколько можно отдать miniApp, не оставив чат без поля ввода.
  double _splitMaxFraction(double available) => math.max(
    _splitMinFraction(available),
    math.min(kMiniAppSplitFullscreenSnap, 1 - _kSplitMinChatHeight / available),
  );

  void _onSplitDragStart(double fraction) {
    _splitDragStart = fraction;
    _splitDragDy = 0;
    setState(() {
      _splitPreview = fraction;
      _resizing = true;
    });
  }

  void _onSplitDragUpdate(double dy, double available) {
    _splitDragDy += dy;
    setState(() {
      _splitPreview = (_splitDragStart + _splitDragDy / available).clamp(
        _splitMinFraction(available),
        1.0,
      );
    });
  }

  void _onSplitDragCancel() {
    if (_splitPreview == null && !_resizing) return;
    setState(() {
      _splitPreview = null;
      _resizing = false;
    });
  }

  void _onSplitDragEnd(double available) {
    final preview = _splitPreview;
    setState(() {
      _splitPreview = null;
      _resizing = false;
    });
    if (preview == null) return;
    // Дотянули почти до низа — на весь экран; сохранённая доля остаётся
    // прежней, чтобы «двойной экран» вернулся к ней, а не к 90%.
    if (preview >= kMiniAppSplitFullscreenSnap) {
      _manager.setFullscreen(true);
    } else {
      _manager.splitFraction.value = math.min(
        preview,
        _splitMaxFraction(available),
      );
    }
  }

  void _onResizeEnd() {
    if (_resizing) setState(() => _resizing = false);
  }

  /// Фокус ввода внутри панели (поле в самом miniApp), а не в чате.
  bool _focusInPanel() {
    final node = FocusManager.instance.primaryFocus;
    // Scope маршрута Navigator панели получает фокус сам при открытии — это
    // не поле ввода, клавиатуру вызвал чат.
    if (node == null || node is FocusScopeNode) return false;
    final focused = node.context;
    if (focused == null) return false;
    var inPanel = false;
    focused.visitAncestorElements((element) {
      if (element.widget.key == _panelKey) {
        inPanel = true;
        return false;
      }
      return true;
    });
    return inPanel;
  }

  double _splitFraction(double available) => _manager.splitFraction.value.clamp(
    _splitMinFraction(available),
    _splitMaxFraction(available),
  );

  double _splitPanelHeight(MediaQueryData mq) {
    final available = mq.size.height - mq.padding.top;
    // Ужатие под клавиатуру — только здесь, в долю не записывается: после
    // закрытия клавиатуры панель возвращается к выбранной бегунком высоте.
    var height = available * _splitFraction(available);
    final keyboard = mq.viewInsets.bottom;
    // Клавиатура вызвана полем в miniApp — панель не ужимаем: она сверху и
    // клавиатура закрывает чат, а не форму miniApp.
    if (keyboard > 0 && !_focusInPanel()) {
      height = math.min(height, available - keyboard - _kSplitMinChatHeight);
    }
    return math.max(height, kMiniAppSplitMinPanelHeight);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final hasApps = _manager.hasApps;
    final wide = LizaThemes.isColumnModeByWidth(size.width);
    final sideAvailable = size.width >= kMiniAppSideMinWindowWidth;
    final tablet = MiniAppOverlay.isTablet(size);
    final mode = miniAppLayoutModeFor(_manager, size.width, tablet: tablet);
    // Свежий снимок темы — для отдельных окон ОС, которые откроются потом.
    MiniAppWindows.instance.theme = Theme.of(context);
    _manager.reportWindowWidth(size.width);
    // Режим сменился посреди перетаскивания (поворот, ширина окна, «на весь
    // экран» из панели) — ручка размонтирована и onEnd не придёт: не оставляем
    // висеть щит и линию-превью.
    if (mode != MiniAppLayoutMode.split) _splitPreview = null;
    if (mode == MiniAppLayoutMode.sheet) _resizing = false;

    final panel = hasApps
        ? KeyedSubtree(
            key: _panelKey,
            child: _MiniAppLayoutScope(
              mode: mode,
              wide: wide,
              sideAvailable: sideAvailable,
              tablet: tablet,
              onDragUpdate: _onDragUpdate,
              onDragEnd: _onDragEnd,
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
            ),
          )
        : null;

    return AnimatedBuilder(
      animation: Listenable.merge([
        _slideController,
        _manager.panelWidth,
        _manager.splitFraction,
        _manager.chatListCompactable,
      ]),
      builder: (context, _) {
        final t = _slideController.value;
        var childMq = mq;
        var childRect = Rect.fromLTWH(0, 0, size.width, size.height);
        final Rect panelRect;
        var panelMq = mq;
        Rect? dividerRect;
        Rect? splitHandleRect;
        double? splitTop;
        var splitAvailable = 0.0;
        var splitStartFraction = 0.0;
        double? splitPreviewY;
        var compactable = false;
        var targetChildWidth = size.width;

        switch (mode) {
          case MiniAppLayoutMode.side:
            compactable = _compactable && _manager.isExpanded;
            final pw = clampMiniAppPanelWidth(
              _manager.panelWidth.value,
              size.width,
              compactable: compactable,
            );
            // Панель выезжает снизу и уезжает вниз — туда, где появляется
            // свёрнутая плашка (а не вбок, где её потом не найти). Приложение
            // при этом плавно занимает освободившуюся ширину под панелью.
            // Свёртку считаем от ЦЕЛЕВОЙ ширины, а не анимированной: иначе при
            // открытии с запомненной широкой панелью список схлопывался бы
            // рывком в конце анимации.
            targetChildWidth = size.width - pw;
            childRect = Rect.fromLTWH(0, 0, size.width - pw * t, size.height);
            childMq = mq.copyWith(size: childRect.size);
            panelRect = Rect.fromLTWH(
              size.width - pw,
              size.height * (1 - t),
              pw,
              size.height,
            );
            panelMq = mq.copyWith(size: panelRect.size);
            if (t == 1) {
              dividerRect = Rect.fromLTWH(
                size.width - pw - 4,
                0,
                8,
                size.height,
              );
            }
          case MiniAppLayoutMode.split:
            final available = size.height - mq.padding.top;
            final ph = _splitPanelHeight(mq);
            final fullHeight = mq.padding.top + ph;
            final top = fullHeight * t;
            childRect = Rect.fromLTWH(0, top, size.width, size.height - top);
            childMq = (t > 0 ? mq.removePadding(removeTop: true) : mq).copyWith(
              size: childRect.size,
            );
            panelRect = Rect.fromLTWH(
              0,
              top - fullHeight,
              size.width,
              fullHeight,
            );
            // Клавиатура и нижний safe-area — забота чата снизу; панели они
            // не касаются (иначе MainButton miniApp подпрыгнул бы дважды).
            // Верхний safe-area панели отработан Padding'ом ниже — убираем
            // его из MediaQuery, иначе SafeArea контента отступит второй раз.
            panelMq = mq
                .removePadding(removeTop: true, removeBottom: true)
                .removeViewInsets(removeBottom: true)
                .copyWith(size: Size(panelRect.width, ph));
            if (t > 0) {
              splitTop = top;
              splitHandleRect = Rect.fromLTWH(
                (size.width - kMiniAppSplitHandleWidth) / 2,
                top - kMiniAppSplitHandleAbove,
                kMiniAppSplitHandleWidth,
                kMiniAppSplitHandleHeight,
              );
              splitAvailable = available;
              splitStartFraction = ph / available;
            }
            final preview = _splitPreview;
            if (preview != null) {
              splitPreviewY = mq.padding.top + preview * available;
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

        _updateCompact(compactable, targetChildWidth);

        return Stack(
          children: [
            Positioned.fromRect(
              key: const ValueKey('miniapp-host-child'),
              rect: childRect,
              child: MediaQuery(
                data: childMq,
                child: MiniAppHostScope(
                  forceColumnMode: mode == MiniAppLayoutMode.side,
                  compactChatList: _compact,
                  child: widget.child,
                ),
              ),
            ),
            if (hasApps && !_manager.isExpanded)
              Positioned(
                key: const ValueKey('miniapp-host-bar'),
                left: wide
                    ? LizaThemes.navRailWidth + LizaThemes.columnWidth
                    : 0,
                right: 0,
                bottom: 0,
                child: _MiniAppCollapsedBar(manager: _manager),
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
                    child: ColoredBox(
                      color: mode == MiniAppLayoutMode.split
                          ? Theme.of(context).colorScheme.surface
                          : Colors.transparent,
                      child: Padding(
                        // В двойном экране панель сверху: шапку опускаем под
                        // статус-бар, фон за ним — цвет панели.
                        padding: EdgeInsets.only(
                          top: mode == MiniAppLayoutMode.split
                              ? mq.padding.top
                              : 0,
                        ),
                        child: panel,
                      ),
                    ),
                  ),
                ),
              ),
            if (_resizing)
              Positioned.fromRect(
                key: const ValueKey('miniapp-host-shield'),
                rect: panelRect,
                child: MouseRegion(
                  cursor: mode == MiniAppLayoutMode.split
                      ? SystemMouseCursors.resizeRow
                      : SystemMouseCursors.resizeColumn,
                  child: const SizedBox.expand(),
                ),
              ),
            if (splitPreviewY != null)
              Positioned(
                key: const ValueKey('miniapp-host-split-preview'),
                left: 0,
                right: 0,
                top: splitPreviewY - 1.5,
                height: 3,
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            if (splitTop != null)
              Positioned(
                key: const ValueKey('miniapp-host-split-divider'),
                left: 0,
                right: 0,
                top: splitTop - 0.5,
                height: 1,
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
            if (splitHandleRect != null)
              Positioned.fromRect(
                key: const ValueKey('miniapp-host-split-handle'),
                rect: splitHandleRect,
                child: _PanelResizeHandle(
                  axis: Axis.vertical,
                  pillCenterY: kMiniAppSplitHandleAbove,
                  // Старт от фактической высоты панели (её могла ужать
                  // клавиатура), а не от сохранённой доли — без скачка.
                  onStart: () => _onSplitDragStart(splitStartFraction),
                  onUpdate: (dy) => _onSplitDragUpdate(dy, splitAvailable),
                  onEnd: () => _onSplitDragEnd(splitAvailable),
                  onCancel: _onSplitDragCancel,
                ),
              ),
            if (dividerRect != null)
              Positioned.fromRect(
                key: const ValueKey('miniapp-host-divider'),
                rect: dividerRect,
                child: _PanelResizeHandle(
                  onStart: () => _onResizeStart(size.width),
                  onUpdate: (dx) => _onResize(dx, size.width),
                  onEnd: _onResizeEnd,
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
  final bool sideAvailable;
  final bool tablet;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  const _MiniAppLayoutScope({
    required this.mode,
    required this.wide,
    required this.sideAvailable,
    required this.tablet,
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
      sideAvailable != oldWidget.sideAvailable ||
      tablet != oldWidget.tablet;
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
    _manager.detach(app.appId, startPath: startPath);
  }

  Future<void> _shareActiveAppLink() async {
    final app = _manager.activeApp;
    if (app == null) return;
    final state = _contentKeys[app.contentKey]?.currentState;
    if (state is! MiniAppWebViewContentState) return;
    _showToast(L10n.of(context).miniAppCreatingLink, autoHide: false);
    final msg = await state.copyInviteLink();
    if (mounted) _showToast(msg);
  }

  GlobalKey _keyFor(String contentKey) {
    return _contentKeys.putIfAbsent(
      contentKey,
      () => GlobalKey<MiniAppWebViewContentState>(),
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
              sideAvailable: scope.sideAvailable,
              tablet: scope.tablet,
              onDragUpdate: scope.onDragUpdate,
              onDragEnd: scope.onDragEnd,
              onShareLink: _shareActiveAppLink,
              onDetach: miniAppDetachAllowed(context)
                  ? _detachActiveApp
                  : null,
            ),
            Expanded(child: _buildContentStack()),
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
    return IndexedStack(
      index: activeIndex >= 0 ? activeIndex : 0,
      children: [
        for (final app in apps)
          debugBuilder != null
              ? KeyedSubtree(
                  key: _keyFor(app.contentKey),
                  child: debugBuilder(context, app),
                )
              : MiniAppWebViewContent(
                  key: _keyFor(app.contentKey),
                  appUrl: app.appUrl,
                  appId: app.appId,
                  appName: app.appName,
                  host: RoomMiniAppHostApi(
                    room: app.room,
                    appId: app.appId,
                    appUrl: app.appUrl,
                  ),
                  roomId: app.room.id,
                  appType: app.appType,
                  appStartPath: app.appStartPath,
                  onClose: () => _manager.close(app.appId),
                  onMinimize: () => _manager.minimize(),
                ),
      ],
    );
  }
}

/// Граница боковой панели — тянется мышью.
class _PanelResizeHandle extends StatelessWidget {
  /// horizontal — граница боковой панели (тянут по X), vertical — бегунок
  /// двойного экрана (тянут по Y).
  final Axis axis;
  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;
  final VoidCallback onEnd;

  /// Жест отменён (перехвачен) — откатить, не применяя. По умолчанию = onEnd.
  final VoidCallback? onCancel;

  /// Центр пилюли от верха зоны (бегунок двойного экрана: пилюля на стыке,
  /// а не в центре зоны). null — по центру.
  final double? pillCenterY;

  const _PanelResizeHandle({
    this.axis = Axis.horizontal,
    this.pillCenterY,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final vertical = axis == Axis.vertical;
    final pill = Container(
      width: vertical ? 36 : 4,
      height: vertical ? 5 : 40,
      decoration: BoxDecoration(
        color: vertical ? colorScheme.outline : colorScheme.outlineVariant,
        borderRadius: BorderRadius.circular(3),
      ),
    );
    final pillCenterY = this.pillCenterY;
    // Бегунок двойного экрана лежит поверх заголовка чата: translucent и
    // MouseRegion.opaque=false пропускают хит-тест дальше по Stack, так что
    // тап достаётся заголовку, а бегунок забирает только вертикальный drag.
    // У MouseRegion по умолчанию opaque — без этого зона снова глухая.
    final behavior = vertical
        ? HitTestBehavior.translucent
        : HitTestBehavior.opaque;
    return MouseRegion(
      opaque: !vertical,
      hitTestBehavior: behavior,
      cursor: vertical
          ? SystemMouseCursors.resizeRow
          : SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: behavior,
        // Бегунок делит арену с тапом заголовка и побеждает лишь после slop —
        // с down смещение до победы не теряется, граница идёт за пальцем.
        dragStartBehavior: vertical
            ? DragStartBehavior.down
            : DragStartBehavior.start,
        onHorizontalDragStart: vertical ? null : (_) => onStart(),
        onHorizontalDragUpdate: vertical ? null : (d) => onUpdate(d.delta.dx),
        onHorizontalDragEnd: vertical ? null : (_) => onEnd(),
        onHorizontalDragCancel: vertical ? null : onEnd,
        onVerticalDragStart: vertical ? (_) => onStart() : null,
        onVerticalDragUpdate: vertical ? (d) => onUpdate(d.delta.dy) : null,
        onVerticalDragEnd: vertical ? (_) => onEnd() : null,
        onVerticalDragCancel: vertical ? (onCancel ?? onEnd) : null,
        child: Semantics(
          label: L10n.of(context).miniAppResizePanel,
          child: pillCenterY == null
              ? Center(child: pill)
              : Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: EdgeInsets.only(top: pillCenterY - 2.5),
                    child: pill,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Свёрнутая плашка внизу экрана.
///
/// Один miniApp → тап разворачивает.
/// Несколько → тап показывает bottom sheet со списком для переключения.
class _MiniAppCollapsedBar extends StatelessWidget {
  final MiniAppManager manager;

  const _MiniAppCollapsedBar({required this.manager});

  void _onTap(BuildContext context) {
    if (manager.appCount <= 1) {
      manager.expand();
      return;
    }
    // Плашка смонтирована над Router — Navigator для листа берём у роутера.
    final navContext =
        LizaApp.router.routerDelegate.navigatorKey.currentContext;
    if (navContext == null) return;
    showModalBottomSheet(
      context: navContext,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final app in manager.apps)
              ListTile(
                leading: const Icon(Icons.web_asset, size: 24),
                title: Text(app.appName),
                trailing: app.appId == manager.activeAppId
                    ? Icon(
                        Icons.check_circle,
                        color: Theme.of(ctx).colorScheme.primary,
                        size: 20,
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  manager.expand(app.appId);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final activeApp = manager.activeApp;
    if (activeApp == null) return const SizedBox.shrink();

    final otherCount = manager.appCount - 1;
    final label = otherCount > 0
        ? L10n.of(context).miniAppAndOthers(activeApp.appName, otherCount)
        : activeApp.appName;

    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      elevation: 2,
      child: InkWell(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        onTap: () => _onTap(context),
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomPadding),
          child: SizedBox(
            height: kMiniAppCollapsedBarHeight,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(
                  Icons.storefront_outlined,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_up,
                  size: 22,
                  color: colorScheme.onSurfaceVariant,
                ),
                // X — закрыть все
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => manager.closeDocked(),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Header развёрнутого miniApp — название и кнопки управления окном.
class _MiniAppHeader extends StatelessWidget {
  final MiniAppInstance? app;
  final MiniAppManager manager;
  final MiniAppLayoutMode mode;
  final bool wide;

  /// Хватает ли ширины окна на боковую панель (иначе «закрепить» = двойной
  /// экран).
  final bool sideAvailable;

  /// Планшет: двойного экрана нет — без боковой панели закрепить некуда.
  final bool tablet;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  /// «Скопировать ссылку» (invite на текущую страницу). null — кнопки нет.
  final VoidCallback? onShareLink;

  /// «Открепить в отдельное окно». null — окна ОС не поддержаны.
  final VoidCallback? onDetach;

  const _MiniAppHeader({
    required this.app,
    required this.manager,
    required this.mode,
    required this.wide,
    required this.sideAvailable,
    required this.tablet,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.onShareLink,
    this.onDetach,
  });

  Widget? _layoutButton(BuildContext context) {
    final l10n = L10n.of(context);
    if (mode != MiniAppLayoutMode.sheet) {
      return IconButton(
        key: const ValueKey('miniapp-fullscreen'),
        tooltip: l10n.miniAppFullscreen,
        icon: const Icon(Icons.open_in_full, size: 20),
        onPressed: () => manager.setFullscreen(true),
      );
    }
    if (!sideAvailable && tablet) return null;
    return IconButton(
      key: const ValueKey('miniapp-dock'),
      tooltip: sideAvailable
          ? l10n.miniAppRestorePanel
          : l10n.miniAppSplitScreen,
      icon: Icon(
        sideAvailable ? Icons.close_fullscreen : Icons.splitscreen,
        size: 20,
      ),
      onPressed: () => manager.setFullscreen(false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final appName = app?.appName ?? '';
    // Свайп вниз сворачивает только мобильный лист.
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
                  IconButton(
                    key: const ValueKey('miniapp-close'),
                    tooltip: L10n.of(context).close,
                    icon: const Icon(Icons.close, size: 22),
                    onPressed: () {
                      if (app != null) manager.close(app!.appId);
                    },
                  ),
                  Expanded(
                    child: Text(
                      appName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onShareLink != null)
                    IconButton(
                      key: const ValueKey('miniapp-copy-link'),
                      tooltip: L10n.of(context).miniAppCopyLink,
                      icon: const Icon(Icons.link, size: 22),
                      onPressed: onShareLink,
                    ),
                  if (onDetach != null)
                    IconButton(
                      key: const ValueKey('miniapp-detach'),
                      tooltip: L10n.of(context).miniAppDetach,
                      icon: const Icon(Icons.open_in_new, size: 20),
                      onPressed: onDetach,
                    ),
                  ?_layoutButton(context),
                  IconButton(
                    key: const ValueKey('miniapp-minimize'),
                    tooltip: L10n.of(context).miniAppMinimize,
                    icon: const Icon(Icons.minimize, size: 22),
                    onPressed: () => manager.minimize(),
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
