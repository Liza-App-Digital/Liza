import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat/tg_widget/tg_widget_api.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_engine.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_model.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_shim.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_storage.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_tap.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_theme.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_trust.dart';

enum TgWidgetStopReason { watchdog, domLimit, navigation }

/// Что сессия просит у хоста (пузыря). Всё, что трогает UI/ОС, — здесь;
/// сама сессия — чистая логика и проверяется без WebView.
abstract class TgWidgetSessionDelegate {
  void onWidgetSize(double contentHeight);
  void onWidgetReady();
  void onWidgetStopped(TgWidgetStopReason reason);
  void onResizeAnchor(String edge);
  void onWatchPublicData(bool on);
  void openLink(Uri url);
  void openBotChat(String botMxid);
  void copyText(String text);
  void haptic(String kind, String? style);
  Future<({Uint8List bytes, String mime})?> resolveMxc(Uri mxc);
}

class TgWidgetSessionContext {
  final TgWidgetBlock block;
  final TgWidgetTrustKind trust;
  final String? chatType;
  final bool isPreview;
  final bool verifiedBot;
  final String roomId;
  final String eventId;

  /// Ключ Web Storage этого сообщения (`TgWidgetStorage.keyFor`).
  final String storageKey;

  /// `TelegramWidget.viewer`: только там, где виджет может слать запросы.
  final Map<String, Object?>? viewer;

  /// Хоумсерверы, с которых виджету можно отдавать `mxc:` (Liza: сервер
  /// пользователя и сервер бота).
  final Set<String> mxcServers;

  const TgWidgetSessionContext({
    required this.block,
    required this.trust,
    required this.chatType,
    required this.isPreview,
    required this.verifiedBot,
    required this.roomId,
    required this.eventId,
    required this.storageKey,
    this.viewer,
    this.mxcServers = const {},
  });

  bool get isForward => trust == TgWidgetTrustKind.forwarded;

  /// Пересланная копия: запросы только у общего виджета с `allow_queries`.
  bool get queriesAllowed =>
      !isPreview &&
      block.allowQueries &&
      (trust == TgWidgetTrustKind.original || (isForward && block.isShared));

  /// Фон — только оригинал в личке с ботом (как в Telegram).
  bool get backgroundAllowed =>
      queriesAllowed &&
      trust == TgWidgetTrustKind.original &&
      chatType == 'private';

  List<String> get lizaFeatures => verifiedBot ? const ['mxc'] : const [];

  String get botLocalpart {
    final id = block.botId;
    final colon = id.indexOf(':');
    return (id.startsWith('@') && colon > 1 ? id.substring(1, colon) : id)
        .toLowerCase();
  }
}

/// Мост «виджет ↔ хост». Всё, что приходит из WebView, — недоверенное:
/// секрет моста код виджета прочитать может, поэтому права (тап, квота,
/// запросы, mxc) хост проверяет сам.
class TgWidgetSession {
  static const int heartbeatMs = 200;
  static const int maxTaskMs = 500;

  /// Молчание шима, накопленное только на РЕГУЛЯРНЫХ тиках Dart-таймера:
  /// подвисший UI-поток Flutter не должен убивать виджеты.
  static const Duration silenceLimit = Duration(milliseconds: 1000);
  static const Duration startupGrace = Duration(seconds: 3);
  static const Duration hapticWindow = Duration(seconds: 5);
  static const int hapticsPerSecond = 20;
  static const Duration backgroundInterval = Duration(seconds: 5);
  static const int maxNodes = 2000;
  static const int maxMxcImages = 32;
  static const int maxMxcBytes = 4 * 1024 * 1024;
  static const Duration _tick = Duration(milliseconds: 250);

  final TgWidgetSessionContext ctx;
  final TgWidgetSessionDelegate delegate;
  final TgWidgetApi api;
  final TgWidgetOpenIdProvider openId;
  final TgWidgetTapGate tapGate;
  final DateTime Function() _now;

  final String secret;
  final String instanceId;

  TgWidgetEngineHandle? _handle;
  Timer? _watchdog;
  DateTime? _lastTick;
  DateTime? _hostStallAt;
  Duration _silence = Duration.zero;
  bool _sawBeat = false;
  bool _stopped = false;
  bool _disposed = false;
  bool _active;
  TgWidgetTheme _theme;
  TgWidgetInset _inset;
  String? _chatData;
  String? _publicData;
  bool _inFlight = false;
  DateTime? _lastBackground;
  final List<DateTime> _haptics = [];
  int _mxcCount = 0;
  final List<Completer<void>> _activeWaiters = [];
  Map<String, String> _local;
  Map<String, String> _session;

  TgWidgetSession({
    required this.ctx,
    required this.delegate,
    required this.api,
    required this.openId,
    required TgWidgetTheme theme,
    required TgWidgetInset inset,
    required bool active,
    Map<String, String> localStorage = const {},
    TgWidgetTapGate? tapGate,
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       tapGate = tapGate ?? TgWidgetTapGate(now: now),
       _theme = theme,
       _inset = inset,
       _active = active,
       _chatData = ctx.block.chatData,
       _publicData = ctx.block.publicData,
       // Превью: пустое хранилище, ничего не сохраняется (как в Telegram).
       _local = ctx.isPreview ? {} : Map.of(localStorage),
       _session = ctx.isPreview ? {} : TgWidgetStorage.session(ctx.storageKey),
       secret = _randomHex(random ?? Random.secure(), 16),
       instanceId = _randomHex(random ?? Random.secure(), 12);

  static String _randomHex(Random r, int bytes) => List.generate(
    bytes,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  bool get isActive => _active;
  bool get stopped => _stopped;
  String? get chatData => ctx.isForward ? null : _chatData;
  String? get publicData => _publicData;
  Map<String, String> get localStorage => Map.unmodifiable(_local);

  /// Конфиг шима (`__TGW_CFG__`).
  Map<String, Object?> buildConfig({
    required String transport,
    String? parentOrigin,
  }) => {
    'secret': secret,
    'transport': transport,
    'parentOrigin': ?parentOrigin,
    'colorScheme': _theme.colorScheme,
    'themeParams': _theme.themeParams,
    'css': {..._theme.cssVars, ..._inset.cssVars},
    'inset': _inset.toJson(),
    'isActive': _active,
    'isPreview': ctx.isPreview,
    'isForward': ctx.isForward,
    'isShared': ctx.block.isShared,
    'chatType': ctx.isForward || ctx.isPreview ? null : ctx.chatType,
    'chatData': chatData,
    'publicData': _publicData,
    'viewer': ctx.queriesAllowed ? ctx.viewer : null,
    'queriesAllowed': ctx.queriesAllowed,
    'backgroundAllowed': ctx.backgroundAllowed,
    'liza': ctx.lizaFeatures,
    'tmeNames': [ctx.botLocalpart],
    'banned': tgWidgetBannedTags.toList(),
    'maxNodes': maxNodes,
    'maxTaskMs': maxTaskMs,
    'heartbeatMs': heartbeatMs,
    'quota': TgWidgetStorage.quotaBytes,
    'storage': {'local': _local, 'session': _session},
  };

  String buildDocument({required String transport, String? parentOrigin}) =>
      buildTgWidgetDocument(
        widgetHtml: ctx.block.html,
        colorScheme: _theme.colorScheme,
        config: buildConfig(transport: transport, parentOrigin: parentOrigin),
      );

  void attach(TgWidgetEngineHandle handle) {
    if (_disposed) return;
    _handle = handle;
    _lastTick = _now();
    _silence = Duration.zero;
    _watchdog?.cancel();
    _watchdog = Timer.periodic(_tick, (_) => _checkWatchdog());
  }

  void _checkWatchdog() {
    if (_disposed || _stopped) return;
    final now = _now();
    final last = _lastTick ?? now;
    _lastTick = now;
    final delta = now.difference(last);
    // Наш собственный таймер опоздал — завис UI-поток Flutter, а не виджет.
    if (delta > _tick * 2) {
      _hostStallAt = now;
      return;
    }
    if (!_active) return;
    _silence += delta;
    final limit = _sawBeat ? silenceLimit : startupGrace;
    if (_silence > limit) {
      _stop(
        TgWidgetStopReason.watchdog,
        _sawBeat ? 'silence' : 'no-heartbeat-at-start',
      );
    }
  }

  /// На Web sandbox-iframe делит поток со страницей Лизы: долгий кадр Flutter
  /// виден шиму как разрыв тиков. Если в то же окно опоздал и наш таймер —
  /// завис хост, а не виджет.
  bool _hostStalledWithin(num ms) {
    final now = _now();
    final last = _lastTick;
    if (last != null && now.difference(last) > _tick * 2) return true;
    final stall = _hostStallAt;
    return stall != null &&
        now.difference(stall) < Duration(milliseconds: ms.toInt()) + _tick * 2;
  }

  void _stop(TgWidgetStopReason reason, [String detail = '']) {
    if (_stopped || _disposed) return;
    _stopped = true;
    _watchdog?.cancel();
    // warn, а не info: в релизной сборке info не печатается, и причину
    // остановки было не узнать.
    Logs().w('[TgWidget] остановлен: ${reason.name} $detail'.trim());
    delegate.onWidgetStopped(reason);
  }

  void onUnexpectedNavigation() => _stop(TgWidgetStopReason.navigation);

  void onPointer(PointerEvent event) => tapGate.onPointer(event);

  void onActivation() => tapGate.onActivation();

  void setFeedScrolling(bool scrolling) => tapGate.setFeedScrolling(scrolling);

  /// Тап засчитывает ТОЛЬКО хост; номер тапа из шима не учитывается вовсе.
  bool _consumeTap() => !ctx.isPreview && tapGate.consume();

  Future<void> _send(Map<String, Object?> msg) async {
    final handle = _handle;
    if (handle == null || _disposed) return;
    await handle.send(jsonEncode({...msg, 's': secret}));
  }

  void handleRaw(String raw) {
    if (_disposed || _stopped) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map || decoded['s'] != secret) return;
    final msg = decoded;
    switch (msg['t']) {
      case 'hb':
        _sawBeat = true;
        _silence = Duration.zero;
        final n = msg['n'];
        final gap = msg['gap'];
        if (n is int && n > maxNodes) {
          _stop(TgWidgetStopReason.domLimit, 'nodes=$n');
        }
        // Шим сам меряет дрейф между тиками по performance.now(): задача
        // длиннее 500 мс видна, даже если её прервали к следующему тику.
        if (gap is num &&
            gap > heartbeatMs + maxTaskMs &&
            !_hostStalledWithin(gap)) {
          _stop(TgWidgetStopReason.watchdog, 'gap=${gap.round()}ms');
        }
      case 'loaded':
        _sawBeat = true;
        _silence = Duration.zero;
        delegate.onWidgetReady();
      case 'ready':
        delegate.onWidgetReady();
      case 'size':
        final h = msg['h'];
        if (h is num && h >= 0) delegate.onWidgetSize(h.toDouble());
      case 'dom':
        _stop(TgWidgetStopReason.domLimit);
      case 'longtask':
        final ms = msg['ms'];
        if (ms is num && ms > maxTaskMs && !_hostStalledWithin(ms)) {
          _stop(TgWidgetStopReason.watchdog, 'longtask=${ms.round()}ms');
        }
      case 'anchor':
        final edge = msg['edge'];
        if (edge == 'top' || edge == 'bottom') {
          delegate.onResizeAnchor(edge as String);
        }
      case 'watch':
        if (ctx.block.isShared && !ctx.isPreview) {
          delegate.onWatchPublicData(msg['on'] == true);
        }
      case 'request':
        unawaited(_handleRequest(msg));
      case 'openLink':
        final url = _validLink(msg['url'], telegram: false);
        if (url != null && _consumeTap()) delegate.openLink(url);
      case 'openTelegramLink':
        final url = _validLink(msg['url'], telegram: true);
        if (url == null) return;
        final name = url.pathSegments.isEmpty
            ? ''
            : url.pathSegments.first.toLowerCase();
        if (name != ctx.botLocalpart) return;
        if (_consumeTap()) delegate.openBotChat(ctx.block.botId);
      case 'copyText':
        final text = msg['text'];
        if (text is String &&
            text.isNotEmpty &&
            text.length <= 256 &&
            _consumeTap()) {
          delegate.copyText(text);
        }
      case 'haptic':
        _haptic(msg);
      case 'mxc':
        unawaited(_handleMxc(msg));
      case 'storage':
        unawaited(_handleStorage(msg));
    }
  }

  Future<void> _handleStorage(Map msg) async {
    if (ctx.isPreview) return;
    final area = msg['area'];
    final data = msg['data'];
    if (data is! Map) return;
    final next = <String, String>{
      for (final e in data.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
    if (area == 'local') {
      if (!await TgWidgetStorage.saveLocal(ctx.storageKey, next)) return;
      _local = next;
    } else if (area == 'session') {
      if (TgWidgetStorage.saveSession(ctx.storageKey, next)) _session = next;
    }
  }

  static bool _isTelegramHost(String host) {
    final h = host.toLowerCase();
    return const [
      't.me',
      'telegram.me',
      'telegram.dog',
    ].any((t) => h == t || h.endsWith('.$t'));
  }

  /// Как у Telegram: только https, ≤256 символов, без `user:pass@`.
  Uri? _validLink(Object? raw, {required bool telegram}) {
    if (raw is! String || raw.isEmpty || raw.length > 256) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    if (uri.userInfo.isNotEmpty) return null;
    if (_isTelegramHost(uri.host) != telegram) return null;
    return uri;
  }

  void _haptic(Map msg) {
    if (!_active || ctx.isPreview) return;
    final now = _now();
    final last = tapGate.lastTouch;
    if (last == null || now.difference(last) > hapticWindow) return;
    _haptics.removeWhere((t) => now.difference(t) > const Duration(seconds: 1));
    if (_haptics.length >= hapticsPerSecond) return;
    final kind = msg['kind'];
    final style = msg['style'];
    if (kind is! String) return;
    _haptics.add(now);
    delegate.haptic(kind, style is String ? style : null);
  }

  Future<void> _handleRequest(Map msg) async {
    final id = msg['id'];
    final data = msg['data'];
    if (id is! int) return;
    Future<void> reply(TgWidgetQueryResult r) => _send({
      't': 'result',
      'id': id,
      'ok': r.ok,
      'result': ?r.result,
      'code': ?r.code,
    });
    const notAllowed = TgWidgetQueryResult.error(TgWidgetErrorCode.notAllowed);

    if (data is! String) {
      return reply(
        const TgWidgetQueryResult.error(TgWidgetErrorCode.badRequest),
      );
    }
    final len = utf8.encode(data).length;
    if (len < 1 || len > 64) {
      return reply(
        const TgWidgetQueryResult.error(TgWidgetErrorCode.badRequest),
      );
    }
    if (!ctx.queriesAllowed) return reply(notAllowed);
    if (_inFlight) {
      return reply(const TgWidgetQueryResult.error(TgWidgetErrorCode.busy));
    }
    // Был ли тап — решает хост. Нет тапа = фоновый запрос, а он разрешён
    // только оригиналу в личке и не чаще раза в 5 с.
    final background = !_consumeTap();
    if (background) {
      if (!ctx.backgroundAllowed) return reply(notAllowed);
      final last = _lastBackground;
      if (last != null && _now().difference(last) < backgroundInterval) {
        return reply(
          const TgWidgetQueryResult.error(TgWidgetErrorCode.rateLimited),
        );
      }
    }
    _inFlight = true;
    try {
      // Фоновый вызов при загрузке ждёт, пока виджет появится на экране.
      if (background && !_active) {
        final waiter = Completer<void>();
        _activeWaiters.add(waiter);
        await waiter.future;
        if (_disposed) return;
      }
      if (background) _lastBackground = _now();
      final original = ctx.trust == TgWidgetTrustKind.original;
      final result = await api.query(
        openId: openId,
        widgetId: ctx.block.widgetId,
        data: data,
        background: background,
        instanceId: instanceId,
        roomId: original ? ctx.roomId : null,
        eventId: original ? ctx.eventId : null,
      );
      if (_disposed) return;
      await reply(result);
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _handleMxc(Map msg) async {
    final id = msg['id'];
    final raw = msg['url'];
    if (id is! int || raw is! String) return;
    Future<void> fail() => _send({'t': 'mxc', 'id': id});
    if (!ctx.lizaFeatures.contains('mxc') || _mxcCount >= maxMxcImages) {
      return fail();
    }
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'mxc' ||
        uri.host.isEmpty ||
        uri.pathSegments.length != 1 ||
        !ctx.mxcServers.contains(uri.host.toLowerCase())) {
      return fail();
    }
    _mxcCount++;
    final media = await delegate.resolveMxc(uri);
    if (_disposed) return;
    if (media == null ||
        media.bytes.isEmpty ||
        media.bytes.length > maxMxcBytes ||
        !media.mime.startsWith('image/')) {
      return fail();
    }
    await _send({
      't': 'mxc',
      'id': id,
      'b64': base64Encode(media.bytes),
      'mime': media.mime,
    });
  }

  Future<void> setActive(bool active) async {
    if (_active == active || _disposed) return;
    _active = active;
    if (active) {
      // В скрытом состоянии таймеры шима редки — свежий отсчёт молчания.
      _silence = Duration.zero;
      _lastTick = _now();
      for (final w in _activeWaiters) {
        if (!w.isCompleted) w.complete();
      }
      _activeWaiters.clear();
    }
    await _send({'t': 'active', 'on': active});
  }

  Future<void> setTheme(TgWidgetTheme theme) async {
    if (theme.sameAs(_theme)) return;
    _theme = theme;
    await _send({
      't': 'theme',
      'colorScheme': theme.colorScheme,
      'themeParams': theme.themeParams,
      'css': theme.cssVars,
    });
  }

  Future<void> setInset(TgWidgetInset inset) async {
    if (inset == _inset) return;
    _inset = inset;
    await _send({'t': 'inset', 'inset': inset.toJson(), 'css': inset.cssVars});
  }

  Future<void> setState({String? chatData, String? publicData}) async {
    if (chatData == _chatData && publicData == _publicData) return;
    _chatData = chatData;
    _publicData = publicData;
    await _send({
      't': 'state',
      'chatData': ctx.isForward ? null : chatData,
      'publicData': publicData,
    });
  }

  Future<Uint8List?> snapshot() async => _handle?.snapshot();

  void dispose() {
    _disposed = true;
    _watchdog?.cancel();
    _handle = null;
    for (final w in _activeWaiters) {
      if (!w.isCompleted) w.complete();
    }
    _activeWaiters.clear();
  }
}
