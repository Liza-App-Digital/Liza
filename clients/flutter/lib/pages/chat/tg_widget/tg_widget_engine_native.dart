import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat/tg_widget/tg_widget_engine.dart';

Widget buildNativeTgWidgetEngine(TgWidgetEngineConfig config) =>
    NativeTgWidgetEngine(config: config);

/// Схемы, которые движку можно грузить: всё остальное — сеть.
const Set<String> tgWidgetLocalSchemes = {'data', 'blob', 'about'};

/// Сетевой выключатель на уровне движка (не шима): разрешены только
/// `data:`/`blob:`/`about:`. Android и Windows (WebView2) зовут перехват для
/// каждой загрузки; `null` — пропустить, ответ-заглушка — заблокировать.
bool tgWidgetRequestAllowed(Uri? url) =>
    url != null && tgWidgetLocalSchemes.contains(url.scheme.toLowerCase());

/// Настройки WebView виджета. Каждая — слой защиты поверх CSP шима.
bool _isApple(TargetPlatform p) =>
    p == TargetPlatform.iOS || p == TargetPlatform.macOS;

/// Сетевой выключатель по платформам: Android — `blockNetworkLoads` +
/// перехват, Windows (WebView2) — перехват всех загрузок
/// (`AddWebResourceRequestedFilter("*")`), iOS/macOS — WKContentRuleList.
InAppWebViewSettings tgWidgetWebViewSettings({
  TargetPlatform? platform,
  bool scrollable = false,
}) {
  final p = platform ?? defaultTargetPlatform;
  return InAppWebViewSettings(
    javaScriptEnabled: true,
    // Неперсистентное хранилище: ни cookies, ни кэша между виджетами и mini
    // app. Web Storage виджета держит хост (по сообщению), не WebView.
    incognito: true,
    cacheEnabled: false,
    thirdPartyCookiesEnabled: false,
    sharedCookiesEnabled: false,
    domStorageEnabled: false,
    databaseEnabled: false,
    // Android: сеть закрыта в WebSettings, плюс перехват каждой загрузки.
    blockNetworkLoads: true,
    blockNetworkImage: true,
    useShouldInterceptRequest: true,
    safeBrowsingEnabled: false,
    allowFileAccess: false,
    allowContentAccess: false,
    allowFileAccessFromFileURLs: false,
    allowUniversalAccessFromFileURLs: false,
    geolocationEnabled: false,
    saveFormData: false,
    javaScriptCanOpenWindowsAutomatically: false,
    supportMultipleWindows: false,
    transparentBackground: true,
    supportZoom: false,
    builtInZoomControls: false,
    displayZoomControls: false,
    verticalScrollBarEnabled: false,
    horizontalScrollBarEnabled: false,
    disableVerticalScroll: !scrollable,
    disableHorizontalScroll: true,
    disableContextMenu: true,
    disableLongPressContextMenuOnLinks: true,
    allowsLinkPreview: false,
    isTextInteractionEnabled: false,
    mediaPlaybackRequiresUserGesture: true,
    allowsInlineMediaPlayback: false,
    allowsAirPlayForMediaPlayback: false,
    allowsPictureInPictureMediaPlayback: false,
    isInspectable: false,
    useShouldOverrideUrlLoading: true,
    useOnDownloadStart: false,
    // Тему задаёт `<meta name="color-scheme">`; авто-затемнение Android
    // перекрасило бы виджет поверх его же CSS.
    algorithmicDarkeningAllowed: false,
    forceDark: ForceDark.OFF,
    // iOS/macOS: WKContentRuleList — блок всего, кроме data/blob/about.
    // `IGNORE_PREVIOUS_RULES` плагин знает только на Apple.
    contentBlockers: _isApple(p) ? tgWidgetContentBlockers() : null,
  );
}

/// Правила WKContentRuleList: блок всего, кроме `data:`/`blob:`/`about:` —
/// по отдельному правилу-исключению на схему. Regex-движок WebKit в
/// content-rule-list (Yarr) НЕ поддерживает дизъюнкцию: `^(data|blob|about):`
/// даёт «Disjunctions are not supported yet», список не компилируется, и
/// flutter_inappwebview (`makeInitialLoad`) на ошибке компиляции молча НЕ
/// зовёт `load(...)` — документ не выполняется, сообщений шима нет, виджет
/// умирает по сторожу. Поэтому схемы перечислены отдельными правилами.
List<ContentBlocker> tgWidgetContentBlockers() => [
  ContentBlocker(
    trigger: ContentBlockerTrigger(urlFilter: '.*'),
    action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
  ),
  for (final scheme in tgWidgetLocalSchemes)
    ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: '^$scheme:'),
      action: ContentBlockerAction(
        type: ContentBlockerActionType.IGNORE_PREVIOUS_RULES,
      ),
    ),
];

/// Чего не хватает настройкам до сетевого выключателя. Движок с непустым
/// списком не создаётся (страховка от «случайно убрали настройку»).
List<String> tgWidgetSettingsViolations(
  InAppWebViewSettings s, {
  TargetPlatform? platform,
}) => _violations(s, platform ?? defaultTargetPlatform);

List<String> _violations(InAppWebViewSettings s, TargetPlatform p) => [
  if (s.blockNetworkLoads != true) 'blockNetworkLoads',
  if (s.useShouldInterceptRequest != true) 'useShouldInterceptRequest',
  if (s.useShouldOverrideUrlLoading != true) 'useShouldOverrideUrlLoading',
  if (s.incognito != true) 'incognito',
  if (s.javaScriptCanOpenWindowsAutomatically != false)
    'javaScriptCanOpenWindowsAutomatically',
  if (s.supportMultipleWindows != false) 'supportMultipleWindows',
  if (s.allowFileAccess != false) 'allowFileAccess',
  if (_isApple(p) &&
      !(s.contentBlockers ?? const <ContentBlocker>[]).any(
        (b) =>
            b.trigger.urlFilter == '.*' &&
            b.action.type == ContentBlockerActionType.BLOCK,
      ))
    'contentBlockers',
];

/// Первая загрузка — наш документ из памяти (`about:blank`); любая другая
/// навигация — отказ.
NavigationActionPolicy tgWidgetNavigationPolicy({
  required WebUri? url,
  required bool isForMainFrame,
  required bool initialLoadDone,
}) {
  if (!initialLoadDone &&
      isForMainFrame &&
      url != null &&
      url.scheme == 'about' &&
      url.path == 'blank') {
    return NavigationActionPolicy.ALLOW;
  }
  return NavigationActionPolicy.CANCEL;
}

class NativeTgWidgetEngine extends StatefulWidget {
  final TgWidgetEngineConfig config;

  /// Шов для теста страховки настроек.
  @visibleForTesting
  final InAppWebViewSettings? debugSettings;

  const NativeTgWidgetEngine({
    super.key,
    required this.config,
    this.debugSettings,
  });

  @override
  State<NativeTgWidgetEngine> createState() => _NativeTgWidgetEngineState();
}

class _NativeTgWidgetEngineState extends State<NativeTgWidgetEngine>
    implements TgWidgetEngineHandle {
  InAppWebViewController? _controller;
  int _loads = 0;
  bool _firstMessage = false;
  late final InAppWebViewSettings _settings =
      widget.debugSettings ??
      tgWidgetWebViewSettings(scrollable: widget.config.scrollable);
  late final List<String> _violations = tgWidgetSettingsViolations(_settings);

  /// Стадия наружу — только пока виджет жив: после dispose/смены документа
  /// поздние колбэки плагина уже ничего не значат.
  void _stage(String stage) {
    if (!mounted) return;
    widget.config.onStage(stage);
  }

  @override
  void dispose() {
    _controller = null;
    super.dispose();
  }

  @override
  Future<void> send(String json) async {
    final controller = _controller;
    if (controller == null || !mounted || _loads > 1) return;
    try {
      await controller.evaluateJavascript(
        source: 'window.__tgwIn && window.__tgwIn(${jsonEncode(json)});',
      );
    } catch (e) {
      Logs().v('[TgWidget] send: ${e.runtimeType}');
    }
  }

  @override
  Future<Uint8List?> snapshot() async {
    final controller = _controller;
    if (controller == null || !mounted) return null;
    try {
      return await controller.takeScreenshot(
        screenshotConfiguration: ScreenshotConfiguration(
          compressFormat: CompressFormat.PNG,
        ),
      );
    } catch (e) {
      Logs().v('[TgWidget] snapshot: ${e.runtimeType}');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    if (_violations.isNotEmpty) {
      Logs().e('[TgWidget] небезопасные настройки WebView: $_violations');
      return const SizedBox.expand(key: ValueKey('tg-widget-engine-refused'));
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: config.onPointer,
      onPointerMove: config.onPointer,
      onPointerUp: config.onPointer,
      onPointerCancel: config.onPointer,
      child: InAppWebView(
        initialData: InAppWebViewInitialData(
          data: config.document,
          baseUrl: WebUri('about:blank'),
        ),
        initialSettings: _settings,
        // Вертикаль всегда у ленты чата (профиль 1 без прокрутки), тапы и
        // горизонтальные жесты — виджету.
        gestureRecognizers: {
          Factory<TapGestureRecognizer>(TapGestureRecognizer.new),
          Factory<HorizontalDragGestureRecognizer>(
            HorizontalDragGestureRecognizer.new,
          ),
        },
        onWebViewCreated: (controller) {
          _controller = controller;
          controller.addJavaScriptHandler(
            handlerName: 'tgw',
            callback: (args) {
              // После смены документа мост молчит: это уже не наш код.
              if (!mounted || _controller != controller || _loads > 1) {
                return null;
              }
              if (!_firstMessage) {
                _firstMessage = true;
                _stage(TgWidgetEngineStage.firstMessage);
              }
              if (args.isNotEmpty && args.first is String) {
                config.onMessage(args.first as String);
              }
              return null;
            },
          );
          _stage(TgWidgetEngineStage.created);
          config.onCreated(this);
        },
        shouldOverrideUrlLoading: (controller, action) async =>
            tgWidgetNavigationPolicy(
              url: action.request.url,
              isForMainFrame: action.isForMainFrame,
              initialLoadDone: _loads > 0,
            ),
        shouldInterceptRequest: (controller, request) async =>
            tgWidgetRequestAllowed(request.url)
            ? null
            : WebResourceResponse(
                contentType: 'text/plain',
                statusCode: 403,
                reasonPhrase: 'Forbidden',
                data: Uint8List(0),
              ),
        // iOS для initialData эти колбэки не зовёт (проверено на симуляторе
        // iOS 26.5: в логе created → firstMessage), поэтому «документ не
        // выполнился» может прийти со стадией created — это и есть ответ.
        onLoadStart: (controller, url) {
          if (!mounted || _controller != controller) return;
          _stage(TgWidgetEngineStage.loadStarted);
        },
        onLoadStop: (controller, url) {
          if (!mounted || _controller != controller) return;
          _stage(TgWidgetEngineStage.loadStopped);
          _loads++;
          if (_loads > 1) config.onUnexpectedNavigation();
        },
        // Ошибки только фиксируем: заблокированная картинка или отменённый
        // запрос — не повод гасить виджет. Стадия нужна для разбора, почему
        // документ не выполнился (например, content-rule-list не скомпилился).
        onReceivedError: (controller, request, error) {
          if (!mounted || _controller != controller) return;
          _stage(TgWidgetEngineStage.failed(error.type));
        },
        onReceivedHttpError: (controller, request, errorResponse) {
          if (!mounted || _controller != controller) return;
          _stage(
            TgWidgetEngineStage.failed(errorResponse.statusCode ?? 'http'),
          );
        },
        onCreateWindow: (controller, action) async => false,
        onPermissionRequest: (controller, request) async => PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.DENY,
        ),
        onJsAlert: (controller, request) async =>
            JsAlertResponse(handledByClient: true),
        onJsConfirm: (controller, request) async => JsConfirmResponse(
          handledByClient: true,
          action: JsConfirmResponseAction.CANCEL,
        ),
        onJsPrompt: (controller, request) async => JsPromptResponse(
          handledByClient: true,
          action: JsPromptResponseAction.CANCEL,
        ),
      ),
    );
  }
}
