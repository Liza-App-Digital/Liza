import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/fluid_page.dart';

/// Статичная HTML-страница — ответ ИИ-бота («жидкий интерфейс»).
///
/// Намеренно НЕ часть mini App: нет JS-мостов, нет initData, нет сети. Файл
/// скачивается клиентом (в E2EE расшифровывается), сверяется с sha256 из
/// маркера и грузится через `initialData` под CSP из [fluidPageDocument];
/// JavaScript в WebView выключен, любая навигация отменяется.
class FluidPageView extends StatefulWidget {
  final Event event;

  const FluidPageView({required this.event, super.key});

  /// Подмена скачивания в widget-тестах.
  @visibleForTesting
  static Future<String> Function(Event event)? debugLoader;

  /// Подмена WebView в widget-тестах: он там не поднимается. Получает
  /// готовый документ (с CSP).
  @visibleForTesting
  static Widget Function(BuildContext context, String document)?
  debugWebViewBuilder;

  @override
  State<FluidPageView> createState() => _FluidPageViewState();
}

class _FluidPageViewState extends State<FluidPageView> {
  late Future<String> _document;

  @override
  void initState() {
    super.initState();
    _document = _load();
  }

  Future<String> _load() async {
    final loader = FluidPageView.debugLoader ?? loadFluidPageHtml;
    return fluidPageDocument(await loader(widget.event));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _document,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          Logs().w('FluidPageView: ${snapshot.error}');
          return Center(
            key: const ValueKey('fluid-page-error'),
            child: Text(L10n.of(context).fluidPageUnavailable),
          );
        }
        final document = snapshot.data;
        if (document == null) {
          return const Center(
            key: ValueKey('fluid-page-loading'),
            child: CircularProgressIndicator.adaptive(),
          );
        }
        final debugBuilder = FluidPageView.debugWebViewBuilder;
        if (debugBuilder != null) return debugBuilder(context, document);
        return ColoredBox(
          color: Colors.white,
          child: InAppWebView(
            key: const ValueKey('fluid-page-webview'),
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
      },
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
