import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/fluid_page_web_frame.dart';
import 'package:liza/utils/fluid_page.dart';

/// Документ страницы из события: скачать (в E2EE — расшифровать), сверить
/// sha256 и размер, обернуть в CSP.
Future<String> loadFluidPageDocument(Event event) async =>
    fluidPageDocument(await loadFluidPageHtml(event));

/// Статичная HTML-страница — ответ ИИ-бота («жидкий интерфейс»).
///
/// Намеренно НЕ часть mini App: нет JS-мостов, нет initData, нет сети.
/// Документ (уже с CSP) отдаёт [loadDocument]: в панели — прямо из события,
/// в отдельном окне ОС — запросом к главному окну (у окна нет Matrix-клиента).
/// JavaScript в WebView выключен, любая навигация отменяется.
class FluidPageView extends StatefulWidget {
  /// Какая страница показана. Сменился — документ грузится заново, а ответ на
  /// прежний запрос отбрасывается (окно ОС одно, в него приходит следующая).
  final String pageKey;
  final Future<String> Function() loadDocument;

  const FluidPageView({
    required this.pageKey,
    required this.loadDocument,
    super.key,
  });

  /// Подмена WebView в widget-тестах: он там не поднимается. Получает
  /// готовый документ (с CSP).
  @visibleForTesting
  static Widget Function(BuildContext context, String document)?
  debugWebViewBuilder;

  @override
  State<FluidPageView> createState() => _FluidPageViewState();
}

class _FluidPageViewState extends State<FluidPageView> {
  String? _document;
  Object? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FluidPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageKey == widget.pageKey) return;
    _document = null;
    _error = null;
    _load();
  }

  void _retry() {
    setState(() => _error = null);
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    try {
      final document = await widget.loadDocument();
      if (!mounted || request != _request) return;
      setState(() => _document = document);
    } catch (e) {
      Logs().w('FluidPageView: $e');
      if (!mounted || request != _request) return;
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      final l10n = L10n.of(context);
      return Center(
        key: const ValueKey('fluid-page-error'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(l10n.fluidPageUnavailable),
            TextButton(
              key: const ValueKey('fluid-page-retry'),
              onPressed: _retry,
              child: Text(l10n.retry),
            ),
          ],
        ),
      );
    }
    final document = _document;
    if (document == null) {
      return const Center(
        key: ValueKey('fluid-page-loading'),
        child: CircularProgressIndicator.adaptive(),
      );
    }
    final debugBuilder = FluidPageView.debugWebViewBuilder;
    if (debugBuilder != null) return debugBuilder(context, document);
    if (kIsWeb) {
      // Web: InAppWebView — iframe без песочницы, в origin приложения. Здесь —
      // sandbox без скриптов и same-origin; ссылки уходят в новую вкладку.
      return ColoredBox(
        color: Colors.white,
        child: fluidPageWebFrame(fluidPageLinksInNewTab(document)),
      );
    }
    return ColoredBox(
      color: Colors.white,
      child: InAppWebView(
        // Новый документ — новый WebView: initialData читается один раз.
        key: ValueKey('fluid-page-webview-${widget.pageKey}'),
        initialData: InAppWebViewInitialData(
          data: document,
          baseUrl: WebUri('about:blank'),
        ),
        initialSettings: fluidPageWebViewSettings(),
        // Первая загрузка initialData идёт как about:blank — её пропускаем
        // (CANCEL на всё глушит и саму страницу, см. howItWoks/miniApps/
        // widgets.md); всё остальное, включая ссылки внутри страницы, — нет.
        shouldOverrideUrlLoading: (controller, action) async =>
            fluidPageNavigationAllowed(action.request.url?.toString())
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL,
        onCreateWindow: (controller, action) async => false,
      ),
    );
  }
}

/// Пропускаем только загрузку самого документа.
@visibleForTesting
bool fluidPageNavigationAllowed(String? url) => url == 'about:blank';

@visibleForTesting
InAppWebViewSettings fluidPageWebViewSettings() => InAppWebViewSettings(
  javaScriptEnabled: false,
  javaScriptCanOpenWindowsAutomatically: false,
  supportMultipleWindows: false,
  allowFileAccess: false,
  allowFileAccessFromFileURLs: false,
  allowUniversalAccessFromFileURLs: false,
  allowContentAccess: false,
  geolocationEnabled: false,
  saveFormData: false,
  cacheEnabled: false,
  clearCache: true,
  transparentBackground: false,
);
