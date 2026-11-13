import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/html_message.dart';
import 'package:liza/pages/chat/events/linkified_span.dart';
import 'package:liza/pages/chat/events/media_caption.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_api.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_engine.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_model.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_runtime.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_session.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_storage.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_theme.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_trust.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/client_download_content_extension.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/url_launcher.dart';

enum TgWidgetPhase {
  verifying,
  captionOnly,
  unsupported,
  awaitingStart,

  /// Web, непроверенный бот: только подпись и «откройте в приложении».
  appOnly,
  idle,
  live,
  stopped,
}

String tgWidgetApiBase(Client client) =>
    AppConfig.lizaBotApiBaseForHomeserver(client.homeserver?.host);

/// Пересылка/копирование виджетов разрешены только при scope `forwarding`
/// (D7). Пока scope неизвестен — считаем выключенным (защищённый контент).
bool tgWidgetForwardingEnabled(Client client) {
  final api = TgWidgetApi.forBase(tgWidgetApiBase(client));
  final scopes = api.scopesCached();
  if (scopes == null) unawaited(api.scopes());
  return scopes?.contains('forwarding') ?? false;
}

/// Виджет-сообщение, которое сейчас нельзя пересылать/копировать: scope
/// `forwarding` выключен либо бот подписал `protect_content` (тогда и уже
/// пересланную копию дальше не пускаем).
bool isProtectedTgWidget(Event event) {
  final block = TgWidgetBlock.fromEvent(event);
  if (block == null) return false;
  return block.protectContent || !tgWidgetForwardingEnabled(event.room.client);
}

/// Определение MIME картинки по сигнатуре: зашифрованное медиа (шифротекст)
/// сюда не пройдёт — и картинка просто не покажется.
String? sniffImageMime(Uint8List b) {
  if (b.length < 12) return null;
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return 'image/png';
  }
  if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'image/gif';
  if (b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

/// Хоумсерверы, с которых виджету можно отдать `mxc:`: сервер пользователя
/// и сервер бота (это и есть хоумсерверы Liza, через которые идёт чат).
Set<String> tgWidgetMxcServers(Client client, String botId) => {
  for (final id in [client.userID, botId])
    if (id != null && id.contains(':'))
      id.substring(id.indexOf(':') + 1).toLowerCase(),
};

/// Пузырь виджета Telegram (профиль 1) в ленте. Подпись — под виджетом; без
/// подписи время сообщения лежит поверх низа виджета (`contentSafeAreaInset`).
class TgWidgetBubble extends StatefulWidget {
  /// Исходное событие (не display-версия правки): код и подпись — из него.
  final Event event;
  final Timeline? timeline;
  final bool ownMessage;
  final Color textColor;
  final Color linkColor;
  final Widget? trailingTime;
  final bool isPreview;

  const TgWidgetBubble({
    super.key,
    required this.event,
    required this.timeline,
    required this.ownMessage,
    required this.textColor,
    required this.linkColor,
    this.trailingTime,
    this.isPreview = false,
  });

  static TgWidgetSignatureVerifier verifier = const VodozemacTgWidgetVerifier();

  /// Сколько раз сторож останавливал виджет сообщения: после первой
  /// остановки — одна повторная попытка при следующем показе, после второй —
  /// стоп до перезапуска приложения.
  static final Map<String, int> _stops = {};

  @visibleForTesting
  static void debugReset() => _stops.clear();

  @override
  State<TgWidgetBubble> createState() => TgWidgetBubbleState();
}

class TgWidgetBubbleState extends State<TgWidgetBubble>
    implements TgWidgetSessionDelegate {
  TgWidgetBlock? _block;
  TgWidgetPhase _phase = TgWidgetPhase.verifying;
  TgWidgetTrustKind _trust = TgWidgetTrustKind.captionOnly;
  bool _verifiedBot = false;
  Map<String, Object?>? _viewer;
  Map<String, String> _localStorage = const {};
  TgWidgetSession? _session;
  String? _document;
  TgWidgetSlot _slot = TgWidgetSlot.none;
  Timer? _parkTimer;
  double? _contentHeight;
  String _anchor = 'top';
  Uint8List? _poster;
  VoidCallback? _unwatch;
  ScrollPosition? _position;
  bool _visibilityScheduled = false;
  bool _wasVisible = false;
  final GlobalKey _timeKey = GlobalKey();

  @visibleForTesting
  TgWidgetPhase get phase => _phase;

  @visibleForTesting
  TgWidgetSession? get session => _session;

  @visibleForTesting
  TgWidgetSlot get slot => _slot;

  TgWidgetBlock get _b => _block!;

  Client get _client => widget.event.room.client;

  TgWidgetApi get _api => TgWidgetApi.forBase(tgWidgetApiBase(_client));

  String get _storageKey => TgWidgetStorage.keyFor(
    userId: _client.userID ?? '',
    roomId: widget.event.room.id,
    eventId: widget.event.eventId,
  );

  @override
  void initState() {
    super.initState();
    _block = resolveTgWidgetState(widget.event, widget.timeline);
    if (_block == null) {
      _phase = TgWidgetPhase.captionOnly;
      return;
    }
    if (!TgWidgetEngines.supported) {
      _phase = TgWidgetPhase.unsupported;
      return;
    }
    unawaited(_api.scopes());
    unawaited(
      _evaluate().catchError((Object e, StackTrace st) {
        Logs().w('[TgWidget] проверка виджета не удалась', e, st);
        if (mounted) setState(() => _phase = TgWidgetPhase.captionOnly);
      }),
    );
  }

  String? get _chatType {
    final room = widget.event.room;
    if (room.isDirectChat) return 'private';
    if (room.isChannel) return 'channel';
    return 'group';
  }

  bool get _mayQuery =>
      !widget.isPreview &&
      _b.allowQueries &&
      (_trust == TgWidgetTrustKind.original ||
          (_trust == TgWidgetTrustKind.forwarded && _b.isShared));

  /// Всё асинхронное — ДО первого показа: подпись, проверенность бота,
  /// viewer, Web Storage, «Запустить». Тогда выдача слота создаёт WebView
  /// синхронно, без гонок с прокруткой.
  Future<void> _evaluate() async {
    final block = _b;
    final event = widget.event;
    final keys = await _api.widgetKeys(needKid: block.kid);
    if (!mounted) return;
    final trust = evaluateTgWidgetTrust(
      block: block,
      eventSender: event.senderId,
      eventRoomId: event.room.id,
      keys: keys,
      verifier: TgWidgetBubble.verifier,
    );
    if (trust == TgWidgetTrustKind.captionOnly) {
      setState(() => _phase = TgWidgetPhase.captionOnly);
      return;
    }
    _trust = trust;
    final verified = await _api.botVerified(block.botId);
    if (!mounted) return;
    // Web: самонавигацию iframe не предотвратить — непроверенным ботам
    // живого виджета там нет вовсе, только «откройте в приложении».
    if (!verified && TgWidgetEngines.liveOnlyForVerified) {
      setState(() {
        _verifiedBot = false;
        _phase = TgWidgetPhase.appOnly;
      });
      return;
    }
    final started = verified || await TgWidgetStorage.wasStarted(event.eventId);
    final local = widget.isPreview
        ? const <String, String>{}
        : await TgWidgetStorage.loadLocal(_storageKey);
    final viewer = _mayQuery
        ? await _api.viewer(
            accountId: _client.userID ?? '',
            openId: TgWidgetOpenIdCache.forClient(_client),
            widgetId: block.widgetId,
            roomId: trust == TgWidgetTrustKind.original ? event.room.id : null,
            eventId: trust == TgWidgetTrustKind.original ? event.eventId : null,
          )
        : null;
    if (!mounted) return;
    setState(() {
      _verifiedBot = verified;
      _localStorage = local;
      _viewer = viewer;
      final stops = TgWidgetBubble._stops[event.eventId] ?? 0;
      if (stops >= 2) {
        _phase = TgWidgetPhase.stopped;
      } else if (started) {
        _phase = TgWidgetPhase.idle;
      } else {
        _phase = TgWidgetPhase.awaitingStart;
      }
    });
    _scheduleVisibility();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_scheduleVisibility);
      _position?.isScrollingNotifier.removeListener(_onScrolling);
      _position = position;
      _position?.addListener(_scheduleVisibility);
      _position?.isScrollingNotifier.addListener(_onScrolling);
    }
    final session = _session;
    if (session != null) unawaited(session.setTheme(_theme()));
    _scheduleVisibility();
  }

  void _onScrolling() =>
      _session?.setFeedScrolling(_position?.isScrollingNotifier.value ?? false);

  @override
  void didUpdateWidget(TgWidgetBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = resolveTgWidgetState(widget.event, widget.timeline);
    final block = _block;
    if (next != null && block != null) {
      if (next.chatData != block.chatData ||
          next.publicData != block.publicData) {
        _block = next;
        unawaited(
          _session?.setState(
            chatData: next.chatData,
            publicData: next.publicData,
          ),
        );
      }
    }
    _scheduleVisibility();
  }

  @override
  void deactivate() {
    // Элемент ушёл из дерева (смена маршрута/перестановка): слот бюджету
    // возвращаем И сами гасим экземпляр — иначе WebView жил бы без слота.
    TgWidgetLiveBudget.instance.remove(this);
    _applySlot(TgWidgetSlot.none, rebuild: false);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _scheduleVisibility();
  }

  @override
  void dispose() {
    _position?.removeListener(_scheduleVisibility);
    _position?.isScrollingNotifier.removeListener(_onScrolling);
    _parkTimer?.cancel();
    TgWidgetLiveBudget.instance.remove(this);
    _unwatch?.call();
    _session?.dispose();
    super.dispose();
  }

  bool get _wantsLive =>
      _phase == TgWidgetPhase.idle || _phase == TgWidgetPhase.live;

  void _scheduleVisibility() {
    if (_visibilityScheduled || !mounted) return;
    _visibilityScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      if (!mounted) return;
      final fraction = tgWidgetVisibleFraction(context);
      final visible = fraction > 0;
      // «Widget stopped» не навсегда: при новом показе — одна повторная попытка.
      if (visible &&
          !_wasVisible &&
          _phase == TgWidgetPhase.stopped &&
          (TgWidgetBubble._stops[widget.event.eventId] ?? 0) < 2) {
        setState(() => _phase = TgWidgetPhase.idle);
      }
      _wasVisible = visible;
      TgWidgetLiveBudget.instance.update(
        this,
        fraction: _wantsLive ? fraction : 0,
        wantsLive: _wantsLive,
        onChanged: _onSlot,
      );
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _onSlot(TgWidgetSlot slot) {
    if (!mounted) return;
    _applySlot(slot);
  }

  /// Переходы слота синхронны: нет await между «слот выдан» и «экземпляр
  /// создан/погашен», значит слот, выданный во время ухода, не теряется, а
  /// быстрый уход-возврат возвращает ТОТ ЖЕ экземпляр (`activated`).
  void _applySlot(TgWidgetSlot slot, {bool rebuild = true}) {
    final before = _slot;
    if (before == slot) return;
    _slot = slot;
    switch (slot) {
      case TgWidgetSlot.active:
        _parkTimer?.cancel();
        if (_session == null) {
          if (_phase == TgWidgetPhase.idle) _createSession(rebuild: rebuild);
        } else {
          unawaited(_session!.setActive(true));
        }
      case TgWidgetSlot.parked:
        final session = _session;
        if (session == null) return;
        unawaited(_snapshotPoster(session));
        unawaited(session.setActive(false));
        _parkTimer?.cancel();
        _parkTimer = Timer(TgWidgetLiveBudget.parkTimeout, () {
          if (mounted) TgWidgetLiveBudget.instance.expire(this);
        });
      case TgWidgetSlot.none:
        _parkTimer?.cancel();
        _destroySession(rebuild: rebuild);
    }
  }

  void _createSession({required bool rebuild}) {
    final session = TgWidgetSession(
      ctx: TgWidgetSessionContext(
        block: _b,
        trust: _trust,
        chatType: _chatType,
        isPreview: widget.isPreview,
        verifiedBot: _verifiedBot,
        roomId: widget.event.room.id,
        eventId: widget.event.eventId,
        storageKey: _storageKey,
        viewer: _viewer,
        mxcServers: tgWidgetMxcServers(_client, _b.botId),
      ),
      delegate: this,
      api: _api,
      openId: TgWidgetOpenIdCache.forClient(_client),
      theme: _theme(),
      inset: _inset(),
      active: true,
      localStorage: _localStorage,
    );
    session.setFeedScrolling(_position?.isScrollingNotifier.value ?? false);
    final document = session.buildDocument(
      transport: TgWidgetEngines.isWeb ? 'web' : 'native',
      parentOrigin: kIsWeb ? Uri.base.origin : null,
    );
    void apply() {
      _session = session;
      _document = document;
      _phase = TgWidgetPhase.live;
    }

    rebuild ? setState(apply) : apply();
  }

  void _destroySession({required bool rebuild}) {
    final session = _session;
    if (session == null) return;
    _localStorage = session.localStorage;
    _unwatch?.call();
    _unwatch = null;
    session.dispose();
    void apply() {
      _session = null;
      _document = null;
      if (_phase == TgWidgetPhase.live) _phase = TgWidgetPhase.idle;
      _poster = TgWidgetPosters.get(_posterKey);
    }

    rebuild ? setState(apply) : apply();
  }

  Future<void> _snapshotPoster(TgWidgetSession session) async {
    final png = await session.snapshot().timeout(
      const Duration(milliseconds: 400),
      onTimeout: () => null,
    );
    if (png != null) TgWidgetPosters.put(_posterKey, png);
  }

  TgWidgetTheme _theme() => TgWidgetTheme.of(
    Theme.of(context),
    outgoing: widget.ownMessage,
    fontSize: AppConfig.messageFontSize * AppSettings.fontSizeFactor.value,
  );

  TgWidgetInset _inset() {
    if (_b.hasCaption) return const TgWidgetInset();
    final box = _timeKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return const TgWidgetInset();
    return TgWidgetInset(
      bottom: box.size.height + 4,
      cornerRight: box.size.width + 8,
    );
  }

  String get _posterKey =>
      TgWidgetPosters.key(widget.event.eventId, _b.chatData, _b.publicData);

  void _start() {
    unawaited(TgWidgetStorage.markStarted(widget.event.eventId));
    setState(() => _phase = TgWidgetPhase.idle);
    _scheduleVisibility();
  }

  double get _areaHeight {
    final block = _block;
    if (block == null) return TgWidgetSize.minHeight;
    if (block.height != 0) return TgWidgetSize.clampHeight(block.height);
    final content = _contentHeight;
    return content == null
        ? TgWidgetSize.reservedHeight(block)
        : TgWidgetSize.clampHeight(content);
  }

  @visibleForTesting
  double get areaHeight => _areaHeight;

  // ---------------- TgWidgetSessionDelegate ----------------

  @override
  void onWidgetSize(double contentHeight) {
    if (!mounted || _b.height != 0) return;
    final before = _areaHeight;
    final after = TgWidgetSize.clampHeight(contentHeight);
    if (after == before && _contentHeight != null) return;
    setState(() => _contentHeight = contentHeight);
    final delta = after - before;
    if (delta != 0) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _compensate(delta));
    }
  }

  /// Лента перевёрнута (новые снизу). Рост пузыря НИЖЕ вьюпорта сдвинул бы
  /// читаемое — компенсируем. Видимый пузырь: `bottom` — нижний край на месте
  /// (в перевёрнутой ленте так и есть), `top` — держим верхний край, кроме
  /// случая «пользователь внизу ленты»: там прилипаем к низу.
  void _compensate(double delta) {
    if (!mounted) return;
    final scrollable = Scrollable.maybeOf(context);
    final pos = scrollable?.position;
    final ro = context.findRenderObject();
    if (scrollable == null || pos == null || ro is! RenderBox || !ro.attached) {
      return;
    }
    final viewport = scrollable.context.findRenderObject();
    if (viewport is! RenderBox) return;
    final rect = MatrixUtils.transformRect(
      ro.getTransformTo(null),
      Offset.zero & ro.size,
    );
    final view = MatrixUtils.transformRect(
      viewport.getTransformTo(null),
      Offset.zero & viewport.size,
    );
    final reversed = scrollable.axisDirection == AxisDirection.up;
    final visible = rect.overlaps(view);
    final atBottom = reversed && pos.pixels <= pos.minScrollExtent + 1;
    bool shouldShift;
    if (reversed) {
      shouldShift =
          rect.top >= view.bottom || (visible && _anchor == 'top' && !atBottom);
    } else {
      shouldShift = rect.bottom <= view.top || (visible && _anchor == 'bottom');
    }
    if (!shouldShift) return;
    final target = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    pos.jumpTo(target);
  }

  @override
  void onWidgetReady() {
    if (!mounted) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final session = _session;
      if (session == null) return;
      unawaited(session.setInset(_inset()));
      // Постер на случай вытеснения без парковки.
      Timer(const Duration(milliseconds: 1500), () {
        if (mounted && identical(_session, session)) {
          unawaited(_snapshotPoster(session));
        }
      });
    });
  }

  @override
  void onWidgetStopped(TgWidgetStopReason reason) {
    if (!mounted) return;
    final id = widget.event.eventId;
    TgWidgetBubble._stops[id] = (TgWidgetBubble._stops[id] ?? 0) + 1;
    final session = _session;
    if (session != null) unawaited(_snapshotPoster(session));
    _unwatch?.call();
    _unwatch = null;
    session?.dispose();
    _parkTimer?.cancel();
    TgWidgetLiveBudget.instance.remove(this);
    setState(() {
      _session = null;
      _document = null;
      _slot = TgWidgetSlot.none;
      _phase = TgWidgetPhase.stopped;
      _poster = TgWidgetPosters.get(_posterKey);
    });
    _scheduleVisibility();
  }

  @override
  void onResizeAnchor(String edge) => _anchor = edge;

  @override
  void onWatchPublicData(bool on) {
    _unwatch?.call();
    _unwatch = null;
    if (!on) return;
    _unwatch = TgSharedWidgetPoller.instance.watch(_api, _b.widgetId, (data) {
      if (!mounted) return;
      _block = _b.withState(chatData: _b.chatData, publicData: data);
      unawaited(_session?.setState(chatData: _b.chatData, publicData: data));
    });
  }

  @override
  void openLink(Uri url) {
    if (!mounted) return;
    // Имя ≠ URL → UrlLauncher сам спросит подтверждение и покажет ссылку целиком.
    UrlLauncher(
      context,
      url.toString(),
      L10n.of(context).widgetLinkName,
    ).launchUrl();
  }

  @override
  void openBotChat(String botMxid) {
    if (!mounted) return;
    UrlLauncher(context, botMxid).launchUrl();
  }

  @override
  void copyText(String text) {
    if (!mounted) return;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    // Тост показывает сам скопированный текст — пользователь видит, что
    // именно легло в буфер.
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          L10n.of(context).widgetCopied(text),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  @override
  void haptic(String kind, String? style) {
    if (!PlatformInfos.isMobile) return;
    switch (kind) {
      case 'impact':
        switch (style) {
          case 'light' || 'soft':
            unawaited(HapticFeedback.lightImpact());
          case 'heavy' || 'rigid':
            unawaited(HapticFeedback.heavyImpact());
          default:
            unawaited(HapticFeedback.mediumImpact());
        }
      case 'notification':
        unawaited(HapticFeedback.vibrate());
      case 'selection':
        unawaited(HapticFeedback.selectionClick());
    }
  }

  @override
  Future<({Uint8List bytes, String mime})?> resolveMxc(Uri mxc) async {
    try {
      final bytes = await _client.downloadMxcCached(mxc);
      final mime = sniffImageMime(bytes);
      return mime == null ? null : (bytes: bytes, mime: mime);
    } catch (e) {
      Logs().v('[TgWidget] mxc: ${e.runtimeType}');
      return null;
    }
  }

  // ---------------- build ----------------

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.only(left: 16, right: 12, bottom: 6),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              color: widget.textColor.withAlpha(170),
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
        ?widget.trailingTime,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    _scheduleVisibility();
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final block = _block;
    if (block == null || _phase == TgWidgetPhase.captionOnly) {
      return _captionWithTime(force: true);
    }
    if (_phase == TgWidgetPhase.unsupported ||
        _phase == TgWidgetPhase.appOnly) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _captionWithTime(force: true, time: false),
          _note(
            _phase == TgWidgetPhase.appOnly
                ? l10n.widgetOpenInApp
                : l10n.widgetNotSupported,
          ),
        ],
      );
    }

    final width = block.width == 0
        ? double.infinity
        : block.width.toDouble().clamp(
            TgWidgetSize.minWidth,
            TgWidgetSize.maxWidth,
          );
    final radius = BorderRadius.vertical(
      top: const Radius.circular(AppConfig.borderRadius),
      bottom: block.hasCaption
          ? Radius.zero
          : const Radius.circular(AppConfig.borderRadius),
    );
    final area = SizedBox(
      key: const ValueKey('tg-widget-area'),
      width: width,
      height: _areaHeight,
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _areaContent(theme, l10n),
            if (!block.hasCaption && widget.trailingTime != null)
              Positioned(
                right: 8,
                bottom: 4,
                child: KeyedSubtree(key: _timeKey, child: widget.trailingTime!),
              ),
          ],
        ),
      ),
    );
    if (!block.hasCaption) return area;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [area, _captionWithTime()],
    );
  }

  Widget _areaContent(ThemeData theme, L10n l10n) {
    final session = _session;
    final document = _document;
    if (_phase == TgWidgetPhase.live && session != null && document != null) {
      final engine = TgWidgetEngines.builder(
        TgWidgetEngineConfig(
          document: document,
          onMessage: session.handleRaw,
          onCreated: session.attach,
          onPointer: session.onPointer,
          onActivation: session.onActivation,
          onUnexpectedNavigation: session.onUnexpectedNavigation,
        ),
      );
      // Превью инлайн-результата: тап выбирает результат, виджету он не
      // достаётся вовсе (и гейт тапа хоста ничего не засчитает).
      return widget.isPreview
          ? IgnorePointer(
              key: const ValueKey('tg-widget-preview'),
              child: engine,
            )
          : engine;
    }
    final placeholderColor = widget.textColor.withAlpha(18);
    final poster = _poster ?? TgWidgetPosters.get(_posterKey);
    final base = poster != null
        ? Image.memory(
            poster,
            key: const ValueKey('tg-widget-poster'),
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            gaplessPlayback: true,
          )
        : ColoredBox(
            key: const ValueKey('tg-widget-placeholder'),
            color: placeholderColor,
          );
    switch (_phase) {
      case TgWidgetPhase.awaitingStart:
        return Stack(
          fit: StackFit.expand,
          children: [
            base,
            Center(
              child: FilledButton.tonalIcon(
                key: const ValueKey('tg-widget-start'),
                onPressed: _start,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(l10n.widgetStart),
              ),
            ),
          ],
        );
      case TgWidgetPhase.stopped:
        return Stack(
          fit: StackFit.expand,
          children: [
            base,
            Center(
              child: DecoratedBox(
                key: const ValueKey('tg-widget-stopped'),
                decoration: BoxDecoration(
                  color: theme.colorScheme.inverseSurface.withAlpha(200),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Text(
                    l10n.widgetStopped,
                    style: TextStyle(
                      color: theme.colorScheme.onInverseSurface,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      case TgWidgetPhase.verifying:
        return Semantics(label: l10n.widgetLoading, child: base);
      default:
        return base;
    }
  }

  Widget _captionWithTime({bool force = false, bool time = true}) {
    final event = widget.event;
    final display = widget.timeline == null
        ? event
        : event.getDisplayEvent(widget.timeline!);
    final trailing = time ? widget.trailingTime : null;
    final caption = (display.content['body'] as String?) ?? '';
    final child = _TgWidgetCaption(
      event: display,
      text: caption,
      textColor: widget.textColor,
      linkColor: widget.linkColor,
    );
    if (!force && caption.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 12, top: 6, bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          if (trailing != null)
            Align(alignment: Alignment.centerRight, child: trailing),
        ],
      ),
    );
  }
}

class _TgWidgetCaption extends StatefulWidget {
  final Event event;
  final String text;
  final Color textColor;
  final Color linkColor;

  const _TgWidgetCaption({
    required this.event,
    required this.text,
    required this.textColor,
    required this.linkColor,
  });

  @override
  State<_TgWidgetCaption> createState() => _TgWidgetCaptionState();
}

class _TgWidgetCaptionState extends State<_TgWidgetCaption> {
  final List<GestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    disposeRecognizers(_recognizers);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    disposeRecognizers(_recognizers);
    final fontSize =
        AppSettings.fontSizeFactor.value * AppConfig.messageFontSize;
    final linkStyle = TextStyle(
      color: widget.linkColor,
      fontSize: fontSize,
      decoration: TextDecoration.underline,
      decorationColor: widget.linkColor,
    );
    final formatted = captionFormattedHtml(widget.event.content);
    if (formatted != null) {
      return HtmlMessage(
        html: formatted,
        room: widget.event.room,
        textColor: widget.textColor,
        fontSize: fontSize,
        linkStyle: linkStyle,
        onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
        eventId: widget.event.eventId,
      );
    }
    return DefaultTextStyle.merge(
      style: const TextStyle(decoration: TextDecoration.none),
      child: Text.rich(
        TextSpan(
          children: buildLinkifiedSpans(
            context: context,
            text: widget.text,
            textStyle: TextStyle(
              color: widget.textColor,
              fontSize: fontSize,
              decoration: TextDecoration.none,
            ),
            linkStyle: linkStyle,
            onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
            recognizerPool: _recognizers,
          ),
        ),
        textScaler: MediaQuery.textScalerOf(context),
      ),
    );
  }
}
