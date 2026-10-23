import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:matrix/matrix.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/bot_miniapp_registry.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/utils/miniapp_start_path.dart';

/// Точка входа для открытия MiniApp — через глобальный MiniAppManager
/// (хост MiniAppOverlay поверх всего UI).
///
/// СТОРОННИЙ (third_party) app ВРЕМЕННО грузится напрямую (как Liza), пока
/// не достроен доверенный shell-host для sandboxed-iframe (blocker B6). Когда
/// он появится — вернуть маршрут `https://shell.<homeserver.host>/host?app=...`
/// в `_buildInitDataUrl` и держать верхний фрейм только на shell-домене.
/// Куда слать `create-invoice`/`status` платёжного модуля.
///
/// Для **third_party** — всегда наш payment-хост (`AppConfig.miniAppPaymentBaseUrl`),
/// НЕ домен приложения: иначе подписанная `X-Liza-Init-Data` уходит на сервер
/// разработчика, который вернёт произвольный `payment_url` (B-fix, §8.6). Для
/// **first_party** — резолв от `appUrl` (прежнее рабочее поведение, инвариант).
///
/// Вынесено top-level и помечено @visibleForTesting ради RL-стража
/// `RL-thirdparty-invoice-target` (чужой appUrl → target == наш payment-хост).
@visibleForTesting
Uri miniAppPaymentResolve({
  required bool isThirdParty,
  required String appUrl,
  required String path,
}) {
  final base = isThirdParty ? AppConfig.miniAppPaymentBaseUrl : appUrl;
  return Uri.parse(base).resolve(path);
}

/// Разрешена ли оплата для стороннего (third_party) mini App.
///
/// Только когда чужой код изолирован shell-host'ом (sandbox-iframe, initData не в
/// странице): тогда `openInvoice`/`getInvoice` через мост безопасны. При прямой
/// загрузке (shell-host выключен) — G2-блок (тихий fail), чтобы чужой JS не мог
/// инициировать платёж/тянуть инвойсы из одного контекста с мостом.
@visibleForTesting
bool thirdPartyPaymentAllowed({
  required bool isThirdParty,
  required bool shellHostEnabled,
}) =>
    isThirdParty && shellHostEnabled;

/// Фактический платёжный хост Prodamus (форма оплаты / 3DS-шлюз). Намеренно НЕ
/// включает `.prodamus.tech`/`.prodamus.ru` (наш периметр) — иначе third_party
/// навигационный allowlist пускал бы чужой код на нашу инфраструктуру.
@visibleForTesting
bool isProdamusPaymentHost(String? host) {
  if (host == null) return false;
  return host == 'payform.ru' ||
      host.endsWith('.payform.ru') ||
      host == 'payform.online' ||
      host.endsWith('.payform.online') ||
      host == 'securepayform.ru' ||
      host.endsWith('.securepayform.ru');
}

class MiniAppWebView {
  MiniAppWebView._();

  static Future<void> open({
    required BuildContext context,
    required String appUrl,
    required String appId,
    required String appName,
    required Room room,
    String appType = 'first_party',
    String appStartPath = '',
  }) async {
    if (!context.mounted) return;

    // Beacon аналитики активности (LABA-2364 Блок D, D-γ): единая точка открытия
    // mini App (все входы — композер/пилюля/панель/каталог/инвайт — идут сюда).
    // Fire-and-forget, не блокирует и не роняет открытие.
    BotMiniAppRegistry.instance.recordOpen(room.client, appId);

    // Немодально на всех платформах: глобальный MiniAppManager → хост
    // MiniAppOverlay сам выбирает раскладку по ширине окна (боковая панель /
    // двойной экран / на весь экран).
    MiniAppManager.instance.open(
      appUrl: appUrl,
      appId: appId,
      appName: appName,
      room: room,
      appType: appType,
      appStartPath: appStartPath,
    );
  }
}

/// Содержимое WebView miniApp — WebView + bridge + MainButton.
///
/// Живёт в хосте MiniAppOverlay. Сохраняет состояние WebView при сворачивании
/// и смене раскладки через GlobalKey.
class MiniAppWebViewContent extends StatefulWidget {
  final String appUrl;
  final String appId;
  final String appName;
  final Room room;
  final String appType;

  /// Deep-link на конкретную страницу mini App (`#!/tproduct/123`) — открываем
  /// сразу на ней. Пусто — главная.
  final String appStartPath;
  final VoidCallback onClose;
  final VoidCallback? onMinimize;

  const MiniAppWebViewContent({
    required this.appUrl,
    required this.appId,
    required this.appName,
    required this.room,
    this.appType = 'first_party',
    this.appStartPath = '',
    required this.onClose,
    this.onMinimize,
    super.key,
  });

  @override
  State<MiniAppWebViewContent> createState() => MiniAppWebViewContentState();
}

class MiniAppWebViewContentState extends State<MiniAppWebViewContent> {
  InAppWebViewController? _controller;
  String? _resolvedUrl;
  // Текущий URL открытой страницы — для захвата deep-link при «Скопировать
  // ссылку». Обновляется в onLoadStop и onUpdateVisitedHistory (hash-навигация
  // Tilda даёт второй, но не первый). При клике URL добираем синхронно через JS.
  String? _currentUrl;
  // Полная строка initData (+platform/theme), которую shell отдаёт стороннему
  // iframe по запросу через bridge. В URL для third_party НЕ кладём (B1).
  // Подписанная initData БЕЗ транспортных полей (platform/theme_params) — для
  // pull-доставки в shell-iframe через window.__shell.provideInitData (Фаза 1).
  String? _signedInitData;
  bool get _isThirdParty => widget.appType == 'third_party';
  bool _isReady = false;
  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;
  bool _dataSent = false;

  // MainButton state
  bool _mainButtonVisible = false;
  String _mainButtonText = '';
  Color? _mainButtonColor;
  bool _mainButtonActive = true;
  bool _mainButtonProgress = false;

  // Closing confirmation
  bool _needClosingConfirmation = false;

  // Invoice payment state
  bool _isPaymentInProgress = false;
  // Успех оплаты задетекчен на странице Prodamus (инлайн success-экран midget).
  // Только после этого показываем нативный баннер «Готово» — не на форме карты.
  bool _paymentSucceeded = false;
  // WebView сейчас на платёжной странице Prodamus (не на нашей корзине).
  // Гейт для нативной панели возврата, чтобы кнопка «Вернуться в магазин» не
  // мелькала поверх корзины в момент создания invoice (до навигации на midget).
  bool _onPaymentPage = false;
  // invoice_id текущей оплаты — кладём в return-fragment, чтобы mini app после
  // перезагрузки добрал результат (за что/сколько/чек) через getInvoice(id).
  int? _currentInvoiceId;

  /// Инжектится в страницу оплаты Prodamus (наш WebView, чужой SPA).
  ///
  /// 1. Прячет NPS-опрос «Вам было просто совершать покупку?» — его кнопки
  ///    Да/Нет не кликабельны в WebView (#2147) и только мешают.
  /// 2. Детектит инлайн success-экран midget (без смены URL) по тексту
  ///    «успешно оплачен» и зовёт нативный хендлер → показываем баннер «Готово».
  ///
  /// MutationObserver нужен, т.к. midget — SPA: success и опрос появляются
  /// без перезагрузки, onLoadStop повторно не срабатывает.
  static const _paymentPageScript = '''
(function() {
  if (window.__lizaPayObserver) return;
  window.__lizaPayObserver = true;

  function hideSurvey() {
    try {
      var nodes = document.querySelectorAll('button, a, [role="button"]');
      var yes = null, no = null;
      for (var i = 0; i < nodes.length; i++) {
        var t = (nodes[i].textContent || '').trim().toLowerCase();
        if (t === 'да') yes = nodes[i];
        else if (t === 'нет') no = nodes[i];
      }
      if (yes && no) {
        var anc = yes;
        while (anc && !anc.contains(no)) anc = anc.parentElement;
        if (anc && anc !== document.body && anc !== document.documentElement) {
          anc.style.display = 'none';
        }
      }
    } catch (e) {}
  }

  function checkSuccess() {
    if (window.__lizaPaidNotified) return;
    var txt = (document.body && document.body.innerText) || '';
    if (/успешно оплачен/i.test(txt)) {
      window.__lizaPaidNotified = true;
      try {
        window.flutter_inappwebview.callHandler('LizaPaymentHandler', 'success');
      } catch (e) {}
    }
  }

  // Окно принудительной прокрутки верха страницы («Заказ №…», «Сумма платежа»):
  // на узком десктоп-диалоге midget после асинхронного рендера и ресайза вьюпорта
  // (появление панели «Вернуться в магазин») оставляет страницу проскролленной,
  // и верх уходит выше видимой области. run() зовётся на каждый reflow
  // (MutationObserver) и раз в секунду — держим верх первые ~2.5 с, переживая
  // поздние reflow'ы, затем отпускаем, чтобы не мешать прокрутке пользователя.
  var scrollStart = Date.now();
  function run() {
    hideSurvey();
    checkSuccess();
    if (Date.now() - scrollStart < 2500) {
      try { window.scrollTo(0, 0); } catch (e) {}
    }
  }
  run();

  try {
    new MutationObserver(run).observe(
      document.documentElement, { childList: true, subtree: true });
  } catch (e) {}
  // Подстраховка для окружений без надёжного MutationObserver.
  // 360 с — синхронно с продлённым окном оплаты (polling 540 с), чтобы поздний
  // success-экран всё равно был задетекчен бэкап-таймером, а не только observer'ом.
  var n = 0;
  var iv = setInterval(function () { run(); if (++n > 360) clearInterval(iv); }, 1000);
})();
''';

  static const _bridgePolyfill = '''
(function() {
  var queue = [];
  var handler = null;
  window.__lizaBridge = {
    postEvent: function(type, data) {
      var msg = JSON.stringify({eventType: type, eventData: data || {}});
      if (handler) { handler(msg); }
      else { queue.push(msg); }
    },
    _activate: function() {
      handler = function(msg) {
        window.flutter_inappwebview.callHandler('LizaWebAppHandler', msg);
      };
      for (var i = 0; i < queue.length; i++) { handler(queue[i]); }
      queue = [];
    }
  };
})();
''';

  /// Сообщает Flutter актуальный location.href при КАЖДОЙ навигации внутри
  /// страницы. WKWebView на macOS не всегда шлёт onUpdateVisitedHistory на
  /// in-page hashchange (Tilda меняет товар через #!/tproduct/...), поэтому
  /// без этого _currentUrl застревал на load-time-URL и deep-link товара не
  /// захватывался. Слушаем hashchange/popstate + разовый стартовый репорт.
  static const _urlTrackerScript = '''
(function() {
  function report() {
    try {
      window.flutter_inappwebview.callHandler('LizaUrlChanged', window.location.href);
    } catch (e) {}
  }
  window.addEventListener('hashchange', report);
  window.addEventListener('popstate', report);
  report();
})();
''';

  @override
  void initState() {
    super.initState();
    _resolveUrl();
    Future.delayed(const Duration(seconds: 15), () {
      if (mounted && !_isReady && _isLoading) {
        setState(() {
          _isLoading = false;
          _hasError = true;
          _errorMessage = L10n.of(context).miniAppLoadTimeout;
        });
      }
    });
  }

  @override
  void dispose() {
    _controller = null;
    super.dispose();
  }

  /// Создаёт invite-ссылку на ТЕКУЩУЮ страницу mini App и кладёт её в буфер.
  ///
  /// Возвращает текст для показа пользователю (успех/ошибка). UI (баннер/тост)
  /// рисует вызывающая шапка: overlay на мобайле, shell на desktop — иначе
  /// SnackBar уходит ПОД лист mini App (overlay смонтирован поверх Router).
  ///
  /// Текущий URL берём синхронно из webview: hash-навигация Tilda
  /// (`#!/tproduct/...`) не всегда триггерит onUpdateVisitedHistory, поэтому
  /// `_currentUrl` — лишь фоновый кэш-fallback.
  Future<String> copyInviteLink() async {
    final client = widget.room.client;
    final token = client.accessToken;
    final l10n = L10n.of(context);
    if (token == null) return l10n.miniAppLinkFailed;

    // Ссылку создаём на комнату-ЛАУНЧЕР (с com.liza.miniapp.config): redeem и
    // лендинг детектят mini App именно по этому state-event. widget.room может
    // быть DM с launch-карточкой (например чат с «Лизой»), где конфига нет — по
    // такой ссылке mini App не распознаётся. Если у widget.room конфига нет —
    // ищем комнату-лаунчер этого приложения среди комнат пользователя.
    var linkRoom = widget.room;
    if (miniAppLaunchForRoom(widget.room) == null) {
      for (final r in client.rooms) {
        final launch = miniAppLaunchForRoom(r);
        if (launch != null &&
            (launch.appId == widget.appId || launch.appUrl == widget.appUrl)) {
          linkRoom = r;
          break;
        }
      }
    }
    // server_name — домен из room.id (как в cross-HS фиксе инвайт-ссылок).
    final serverName = linkRoom.id.split(':').last;

    var current = _currentUrl;
    try {
      final raw =
          await _controller?.evaluateJavascript(source: 'window.location.href');
      // evaluateJavascript на macOS может вернуть строку в кавычках или не-String —
      // нормализуем, иначе упадём на устаревший _currentUrl и потеряем товар.
      final asStr = raw is String ? raw : raw?.toString();
      if (asStr != null && asStr.isNotEmpty) {
        current = _unquote(asStr);
      }
    } catch (_) {
      // fallback на _currentUrl
    }

    final startPath = current == null
        ? ''
        : extractStartPath(appUrl: widget.appUrl, currentUrl: current);
    final safeStartPath =
        startPath.isNotEmpty && isSafeStartPath(startPath) ? startPath : null;

    // Диагностика захвата deep-link (видно в консоли flutter run): что вернул
    // webview и какой хвост извлекли. Помогает понять, почему start_path пуст.
    // Закомментировано — захват работает; раскомментировать при отладке захвата.
    // Logs().i('[MiniAppWebView] copyInviteLink: appUrl=${widget.appUrl} '
    //     'current=$current startPath="$startPath"');

    try {
      final info = await AuthProxyService().createInvite(
        serverName: serverName,
        roomId: linkRoom.id,
        accessToken: token,
        appStartPath: safeStartPath,
      );
      await Clipboard.setData(ClipboardData(text: info.url));
      return l10n.miniAppLinkCopied;
    } catch (e) {
      Logs().e('[MiniAppWebView] copyInviteLink: $e');
      return l10n.miniAppLinkFailed;
    }
  }

  /// Снимает обрамляющие кавычки, если evaluateJavascript вернул JSON-строку.
  String _unquote(String s) {
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  Future<void> _resolveUrl() async {
    try {
      // НЕ зовём InAppWebViewController.clearAllCache(): на iOS он стирает не
      // только HTTP-кеш, но и localStorage (WKWebsiteDataStore.allWebsiteDataTypes),
      // а в нём miniApp хранит корзину и контактные данные покупателя между
      // сессиями. Свежесть index.html обеспечивают cacheEnabled:false +
      // clearCache:true в InAppWebViewSettings.
      final url = await _buildInitDataUrl();
      if (mounted) {
        setState(() => _resolvedUrl = url);
      }
    } catch (e) {
      // L10n читаем ЗДЕСЬ, а не в начале метода: _resolveUrl() зовётся из
      // initState синхронно, и dependOnInheritedWidgetOfExactType до конца
      // initState даёт assert. Этот блок исполняется уже после первого await.
      if (mounted) {
        setState(() {
          _hasError = true;
          _isLoading = false;
          _errorMessage = L10n.of(context).miniAppPrepareFailed;
        });
      }
    }
  }

  Future<String> _buildInitDataUrl() async {
    final client = widget.room.client;
    String initData;

    try {
      final url = client.homeserver!.resolve(
        '/_synapse/client/miniapp/v1/init_data',
      );
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer ${client.accessToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'app_id': widget.appId,
          'room_id': widget.room.id,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        initData = data['init_data'] as String;
      } else {
        throw Exception('Synapse miniapp module returned ${response.statusCode}');
      }
    } catch (e) {
      // B3: НЕ фабрикуем неподписанную initData с реальным userID при сбое
      // Synapse — это позволяло app выдавать пользователя за себя на своём
      // бэкенде. Нет подписанной initData → приложение не открывается.
      Logs().w('[MiniAppWebView] Synapse init_data недоступен: $e');
      rethrow;
    }

    final extraParams = {
      'platform': _detectPlatform(),
      'theme_params': jsonEncode(_buildThemeParams()),
    };
    final extraFragment = extraParams.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');

    final fullFragment = '$initData&$extraFragment';

    // ВРЕМЕННО (shell-host ещё не достроен, blocker B6): сторонний app грузим
    // НАПРЯМУЮ — как Liza-модель — с подписанной initData в URL-фрагменте.
    // Токен Matrix в страницу не попадает (живёт в Flutter), навигация чужого
    // кода ограничена в shouldOverrideUrlLoading (только домен app + платёжки),
    // window.open и web_app_open_invoice для third_party заблокированы. Когда
    // shell-host заработает — вернуть здесь маршрут на $shellBase/host.
    _signedInitData = initData; // без транспортных полей — для pull в shell

    // Shell-host (Фаза 1): для third_party грузим чужой код в sandboxed-iframe
    // под НАШИМ shell-доменом; initData отдаётся pull'ом (_provideInitDataToShell),
    // НЕ в URL. Прямая загрузка appUrl#initData остаётся для first_party и для
    // third_party, пока shell-host выключен (флаг по умолчанию off).
    if (_isThirdParty && AppConfig.shellHostEnabled) {
      return '${AppConfig.shellHostBaseUrl}/host'
          '?app=${Uri.encodeComponent(widget.appId)}';
    }
    // third_party (прямая загрузка, shell-host выкл): НЕ кладём initData в
    // URL-фрагмент. Сторонний сайт (Tilda) её не читает, а наш фрагмент занимает
    // единственный #-слот и ЛОМАЕТ hash-роутинг товара (#!/tproduct/...): тогда
    // location.href при «Скопировать ссылку» несёт наш lizaWebAppData, и
    // extractStartPath режет маршрут в пусто (отсюда start_path=None у всех
    // ссылок — товар не передавался). initData для third_party-платежей здесь не
    // нужна: G2 их блокирует, пока shell-host выключен, а подписанная initData
    // живёт в _signedInitData для shell-pull. Deep-link (appStartPath) при этом
    // открывает товар: composeMiniAppUrl без initData отдаёт чистый appUrl+startPath.
    if (_isThirdParty) {
      return composeMiniAppUrl(
        appUrl: widget.appUrl,
        startPath: widget.appStartPath,
      );
    }
    // first_party: прежнее поведение — initData в URL-фрагменте (SDK читает её из
    // location.hash); composeMiniAppUrl не затирает deep-link startPath.
    return composeMiniAppUrl(
      appUrl: widget.appUrl,
      startPath: widget.appStartPath,
      initDataFragment: fullFragment,
    );
  }

  /// Отдаёт подписанную initData доверенной shell-странице (third_party).
  /// Чужой iframe внутри shell запрашивает её через урезанный bridge —
  /// напрямую к нативному мосту и к Matrix-токену он доступа не имеет.
  ///
  /// КОНТРАКТ: shell.js `provideInitData` ждёт ОБЪЕКТ
  /// `{init_data, theme_params?, platform?, safe_area?}` (не строку) — иначе в
  /// iframe уйдёт пустая initData (ложно-зелёный). Раньше слалась строка-фрагмент.
  void _provideInitDataToShell() {
    final initData = _signedInitData;
    if (initData == null || _controller == null) return;
    final payload = jsonEncode({
      'init_data': initData,
      'theme_params': _buildThemeParams(),
      'platform': _detectPlatform(),
    });
    _controller!.evaluateJavascript(
      source: 'if(window.__shell&&window.__shell.provideInitData)'
          'window.__shell.provideInitData($payload);',
    );
  }

  bool _isPaymentHost(String? host) => isProdamusPaymentHost(host);

  /// База для вызовов НАШЕГО платёжного модуля (`create-invoice`/`status`).
  /// Делегирует в top-level [miniAppPaymentResolve] (тестируемо, RL-страж).
  Uri _paymentResolve(String path) => miniAppPaymentResolve(
        isThirdParty: _isThirdParty,
        appUrl: widget.appUrl,
        path: path,
      );

  /// Хосты, на которые служебному first_party-порталу (кабинет разработчика)
  /// разрешено навигировать: сам портал, auth-proxy и OIDC-провайдеры — на
  /// случай, если кабинет редиректит на вход через ProdamusID.
  bool _isPortalHost(String? host) {
    if (host == null) return false;
    final portalHost = Uri.parse(AppConfig.developerPortalUrl).host;
    return host == portalHost ||
        host == AppConfig.authProxyBaseUrl ||
        host == 'dev.authv3.prodamus.ru' ||
        host == 'id.prodamus.ru';
  }

  String _detectPlatform() {
    if (Theme.of(context).platform == TargetPlatform.iOS) return 'ios';
    if (Theme.of(context).platform == TargetPlatform.android) return 'android';
    if (Theme.of(context).platform == TargetPlatform.macOS) return 'macos';
    if (Theme.of(context).platform == TargetPlatform.windows) return 'windows';
    if (Theme.of(context).platform == TargetPlatform.linux) return 'linux';
    return 'web';
  }

  Map<String, String> _buildThemeParams() {
    final colorScheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    return {
      'color_scheme': brightness == Brightness.dark ? 'dark' : 'light',
      'bg_color': _colorToHex(colorScheme.surface),
      'secondary_bg_color': _colorToHex(colorScheme.surfaceContainerHigh),
      'text_color': _colorToHex(colorScheme.onSurface),
      'hint_color': _colorToHex(colorScheme.onSurface.withAlpha(128)),
      'link_color': _colorToHex(colorScheme.primary),
      'button_color': _colorToHex(colorScheme.primary),
      'button_text_color': _colorToHex(colorScheme.onPrimary),
      'border_radius': AppConfig.borderRadius.toStringAsFixed(0),
    };
  }

  String _colorToHex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

  void _handleJsEvent(String rawMessage) {
    try {
      final msg = jsonDecode(rawMessage) as Map<String, dynamic>;
      final eventType = msg['eventType'] as String?;
      final eventData = msg['eventData'] as Map<String, dynamic>? ?? {};

      switch (eventType) {
        case 'web_app_ready':
          setState(() {
            _isReady = true;
            _isLoading = false;
          });

        case 'web_app_request_init':
        case 'web_app_request_init_data':
          // Запрос подписанной initData от доверенной shell-страницы (third_party).
          _provideInitDataToShell();

        case 'web_app_close':
          _closeMiniApp();

        case 'web_app_expand':
          setState(() {});

        case 'web_app_send_data':
          _handleSendData(eventData);

        case 'web_app_open_link':
          final url = eventData['url'] as String?;
          if (url != null) _openExternalLink(url);

        case 'web_app_open_popup':
          _showNativePopup(eventData);

        case 'web_app_open_invoice':
          // G2: сторонний app (third_party) может инициировать платёж ТОЛЬКО под
          // shell-изоляцией (чужой код в sandbox-iframe, не в одном контексте с
          // мостом). Пока shell-host выключен — тихо отбиваем. В shell-режиме —
          // через нативный confirm (_handleOpenInvoice, see _showPaymentConfirm).
          if (_isThirdParty &&
              !thirdPartyPaymentAllowed(
                isThirdParty: true,
                shellHostEnabled: AppConfig.shellHostEnabled,
              )) {
            _controller?.evaluateJavascript(
              source:
                  "Liza.WebApp._receiveEvent('invoiceClosed', {status: 'failed'});",
            );
            break;
          }
          _handleOpenInvoice(eventData);

        case 'web_app_get_invoice':
          // Запрос результата оплаты по invoice_id (переживает reload/поздний чек).
          // Для third_party — только под shell-изоляцией (как openInvoice, G2).
          // Доступ к чужому invoice на сервере отсекается scoping'ом по user_hash.
          if (_isThirdParty &&
              !thirdPartyPaymentAllowed(
                isThirdParty: true,
                shellHostEnabled: AppConfig.shellHostEnabled,
              )) {
            _controller?.evaluateJavascript(
              source: "Liza.WebApp._receiveEvent('invoiceResult', null);",
            );
            break;
          }
          _handleGetInvoice(eventData);

        case 'web_app_setup_main_button':
          _updateMainButton(eventData);

        case 'web_app_setup_back_button':
          break;

        case 'web_app_setup_closing_behavior':
          _needClosingConfirmation =
              eventData['need_confirmation'] == true;

        case 'web_app_trigger_haptic_feedback':
          _triggerHaptic(eventData);

        case 'web_app_set_header_color':
        case 'web_app_set_background_color':
          break;
      }
    } catch (e) {
      Logs().w('[MiniAppWebView] JS event parse error: $e');
    }
  }

  Future<void> _handleSendData(Map<String, dynamic> eventData) async {
    if (_dataSent) return;
    _dataSent = true;

    final data = eventData['data'];
    if (data == null) return;
    final dataBody = L10n.of(context).miniAppDataBody;

    final dataStr = data is String ? data : jsonEncode(data);
    if (dataStr.length > 4096) {
      Logs().w('[MiniAppWebView] sendData: данные > 4096 байт, отклонено');
      return;
    }

    try {
      await widget.room.sendEvent({
        'msgtype': 'com.liza.miniapp.data',
        'body': dataBody,
        'app_id': widget.appId,
        'data': data is String ? jsonDecode(data) : data,
      });

      _controller?.evaluateJavascript(
        source: "Liza.WebApp._receiveEvent('dataSent', {});",
      );

      widget.onClose();
    } catch (e) {
      _dataSent = false;
      Logs().e('[MiniAppWebView] sendData failed: $e');
      _controller?.evaluateJavascript(
        source:
            "Liza.WebApp._receiveEvent('sendDataFailed', {error: '${e.toString().replaceAll("'", "\\'")}'});",
      );
    }
  }

  Future<void> _handleOpenInvoice(Map<String, dynamic> eventData) async {
    if (_isPaymentInProgress) return;
    final l10n = L10n.of(context);
    setState(() {
      _isPaymentInProgress = true;
      _paymentSucceeded = false;
      _onPaymentPage = false;
    });

    try {
      final client = widget.room.client;

      // Валидация данных от miniApp
      final title = eventData['title'] as String? ?? '';
      final description = eventData['description'] as String?;
      final currency = eventData['currency'] as String? ?? 'RUB';
      final pricesRaw = eventData['prices'] as List?;
      final payload = eventData['payload'] as String?;
      final customerPhone = eventData['customer_phone'] as String?;
      final customerEmail = eventData['customer_email'] as String?;

      if (title.isEmpty || pricesRaw == null || pricesRaw.isEmpty) {
        _sendInvoiceResult('failed', l10n.miniAppInvalidInvoice);
        return;
      }

      // Получаем initData для авторизации на backend
      String initData;
      try {
        final url = client.homeserver!.resolve(
          '/_synapse/client/miniapp/v1/init_data',
        );
        final response = await http.post(
          url,
          headers: {
            'Authorization': 'Bearer ${client.accessToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'app_id': widget.appId,
            'room_id': widget.room.id,
          }),
        );
        if (response.statusCode != 200) {
          throw Exception('init_data: ${response.statusCode}');
        }
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        initData = data['init_data'] as String;
      } catch (e) {
        Logs().e('[MiniAppWebView] openInvoice: не удалось получить initData: $e');
        _sendInvoiceResult('failed', l10n.miniAppAuthError);
        return;
      }

      // POST на backend /api/payment/create-invoice (для third_party — на НАШ
      // payment-модуль, не на домен приложения; см. _paymentResolve).
      final backendUrl = _paymentResolve('/api/payment/create-invoice');
      final invoiceResponse = await http.post(
        backendUrl,
        headers: {
          'Content-Type': 'application/json',
          'X-Liza-Init-Data': initData,
        },
        body: jsonEncode({
          'app_id': widget.appId,
          'title': title,
          'description': description,
          'currency': currency,
          'prices': pricesRaw,
          'payload': payload,
          'room_id': widget.room.id,
          if (customerPhone != null) 'customer_phone': customerPhone,
          if (customerEmail != null) 'customer_email': customerEmail,
        }),
      );

      if (invoiceResponse.statusCode != 200) {
        Logs().e('[MiniAppWebView] create-invoice failed: ${invoiceResponse.statusCode} ${invoiceResponse.body}');
        _sendInvoiceResult('failed', l10n.miniAppInvoiceFailed);
        return;
      }

      final invoiceData = jsonDecode(invoiceResponse.body) as Map<String, dynamic>;
      final paymentUrl = invoiceData['payment_url'] as String?;
      final invoiceId = invoiceData['invoice_id'] as int?;

      if (paymentUrl == null || paymentUrl.isEmpty) {
        _sendInvoiceResult('failed', l10n.miniAppPaymentUnavailable);
        return;
      }

      // Нативный confirm для стороннего app: чужой JS не может нажать нативную
      // кнопку за пользователя (замена user-gesture). Сумму берём СЕРВЕРНУЮ
      // (total_amount из create-invoice), не из eventData — иначе app показал бы
      // «1 ₽», а списалось бы больше. create-invoice денег не двигает, поэтому
      // создать-затем-подтвердить безопасно.
      if (_isThirdParty) {
        final totalMinor = (invoiceData['total_amount'] as int?) ?? 0;
        final cur = invoiceData['currency'] as String? ?? currency;
        final confirmed = await _showPaymentConfirmSheet(totalMinor, cur);
        if (!confirmed) {
          _sendInvoiceResult('cancelled', null);
          return;
        }
      }

      // Навигация WebView на платёжную страницу Prodamus
      _controller?.loadUrl(
        urlRequest: URLRequest(url: WebUri(paymentUrl)),
      );

      // Ждём возвращения на success/error URL или закрытия
      // Результат придёт через _checkPaymentNavigation + polling
      if (invoiceId != null) {
        _currentInvoiceId = invoiceId;
        _pollInvoiceStatus(invoiceId, initData);
      }
    } catch (e) {
      Logs().e('[MiniAppWebView] openInvoice error: $e');
      _sendInvoiceResult('failed', e.toString());
    }
  }

  /// Нативный лист подтверждения оплаты для стороннего (third_party) app.
  ///
  /// Рисуется в Flutter-дереве ПОВЕРХ WebView — чужой JS до него не дотягивается
  /// (нет общего DOM/цикла событий), поэтому это надёжная замена user-gesture:
  /// платёж нельзя инициировать без явного нативного нажатия пользователя.
  /// Сумма — СЕРВЕРНАЯ (с create-invoice), не из eventData.
  Future<bool> _showPaymentConfirmSheet(int totalMinor, String currency) async {
    if (!mounted) return false;
    final l10n = L10n.of(context);
    final symbol = currency.toUpperCase() == 'RUB' ? '₽' : currency.toUpperCase();
    final amount = '${(totalMinor / 100).toStringAsFixed(2)} $symbol';
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: false,
      showDragHandle: true,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.miniAppPaymentTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.miniAppPaymentRequest(widget.appName),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                Text(
                  amount,
                  textAlign: TextAlign.center,
                  style: Theme.of(sheetContext)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                  child: Text(l10n.miniAppPay(amount)),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                  child: Text(l10n.cancel),
                ),
              ],
            ),
          ),
        );
      },
    );
    return result ?? false;
  }

  /// Получает подписанную initData у Synapse-модуля (для авторизации на backend).
  Future<String?> _fetchSignedInitData() async {
    try {
      final client = widget.room.client;
      final url = client.homeserver!.resolve(
        '/_synapse/client/miniapp/v1/init_data',
      );
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer ${client.accessToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'app_id': widget.appId, 'room_id': widget.room.id}),
      );
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['init_data'] as String?;
    } catch (e) {
      Logs().w('[MiniAppWebView] init_data fetch: $e');
      return null;
    }
  }

  /// Отдаёт mini app результат оплаты (за что/сколько/чек) по invoice_id.
  ///
  /// Источник истины — наш платёжный модуль (его статус замыкается webhook'ом).
  /// Позволяет mini app получить чек, пришедший ПОЗЖЕ оплаты (ОФД асинхронен),
  /// и пережить перезагрузку страницы. Ответ — событие `invoiceResult` с тем же
  /// объектом PaymentResult, что и /status.
  Future<void> _handleGetInvoice(Map<String, dynamic> eventData) async {
    final invoiceId = eventData['invoice_id'];
    void reply(String body) => _controller?.evaluateJavascript(
          source: "Liza.WebApp._receiveEvent('invoiceResult', $body);",
        );
    if (invoiceId == null) {
      reply('null');
      return;
    }
    final initData = await _fetchSignedInitData();
    if (initData == null) {
      reply('null');
      return;
    }
    try {
      final url = _paymentResolve('/api/payment/invoice/$invoiceId/status');
      final resp = await http.get(url, headers: {'X-Liza-Init-Data': initData});
      // Тело — JSON от нашего эндпоинта (валидный JS-объектный литерал).
      reply(resp.statusCode == 200 ? resp.body : 'null');
    } catch (e) {
      Logs().w('[MiniAppWebView] getInvoice: $e');
      reply('null');
    }
  }

  Future<void> _pollInvoiceStatus(int invoiceId, String initData) async {
    final backendUrl = _paymentResolve('/api/payment/invoice/$invoiceId/status');

    // 180 × 3с = 540с (9 мин). Раньше было 60 × 3с = 180с — по истечении мы
    // уводили WebView с midget на appUrl, и QR/форма СБП «пропадали» через 3 мин,
    // не дав пользователю доплатить. Окно увеличено ×3 (Prodamus webhook к нам не
    // доходит, polling всегда упирается в этот таймаут).
    for (var i = 0; i < 180; i++) {
      await Future.delayed(const Duration(seconds: 3));
      if (!mounted || !_isPaymentInProgress) return;

      try {
        final response = await http.get(
          backendUrl,
          headers: {'X-Liza-Init-Data': initData},
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final status = data['status'] as String?;

          if (status == 'paid') {
            _returnToShop('paid', data);
            return;
          } else if (status == 'failed') {
            _returnToShop('failed', data);
            return;
          }
          // pending — продолжаем polling
        }
      } catch (e) {
        Logs().w('[MiniAppWebView] polling invoice status: $e');
      }
    }

    // Таймаут ожидания оплаты — возвращаем пользователя в корзину с сохранёнными
    // позициями и данными (см. _returnToShop).
    if (mounted && _isPaymentInProgress) {
      _returnToShop('cancelled');
    }
  }

  /// Отдаёт результат оплаты в miniApp через invoiceClosed.
  ///
  /// [result] — полный объект статуса от платёжного модуля (за что/сколько/чек).
  /// Если задан — прокидываем mini app позиции, сумму, валюту и данные чека, а не
  /// одну строку статуса. SDK сохраняет обратную совместимость: 1-й аргумент
  /// колбэка остаётся строкой `status`, объект доступен 2-м аргументом/через onEvent.
  void _sendInvoiceResult(
    String status,
    String? error, [
    Map<String, dynamic>? result,
  ]) {
    if (mounted) {
      setState(() {
        _isPaymentInProgress = false;
        _paymentSucceeded = false;
        _onPaymentPage = false;
      });
    } else {
      _isPaymentInProgress = false;
      _paymentSucceeded = false;
      _onPaymentPage = false;
    }
    final payload = <String, dynamic>{'status': status};
    if (error != null) payload['error'] = error;
    if (result != null) {
      for (final k in const [
        'invoice_id',
        'amount',
        'currency',
        'items',
        'payload',
        'paid_at',
        'receipt',
      ]) {
        if (result[k] != null) payload[k] = result[k];
      }
    }
    // jsonEncode → корректное экранирование (имена позиций/чек со спецсимволами)
    // вместо ручной сборки строки.
    _controller?.evaluateJavascript(
      source: "Liza.WebApp._receiveEvent('invoiceClosed', ${jsonEncode(payload)});",
    );
  }

  /// Ручной возврат с формы оплаты в miniApp.
  ///
  /// ВРЕМЕННЫЙ обход: midget (ПФ2) — SPA, успех показывает инлайн без смены URL,
  /// а webhook Prodamus к нам не доходит (notification-URL настраивается только
  /// в ЛК мерчанта, у тестового мерчанта он не наш). Поэтому автоматически
  /// подтвердить оплату нечем — даём пользователю нативную кнопку выхода, чтобы
  /// он не залипал на чужом success-экране (кнопки которого ещё и не кликабельны
  /// из-за бага flutter_inappwebview #2147 на macOS).
  /// Настоящее подтверждение появится при переходе на ПФ1 + urlNotification
  /// либо настройке webhook в ЛК — тогда статус подтвердит polling/webhook.
  void _returnToShop(String status, [Map<String, dynamic>? result]) {
    // Грузим _resolvedUrl (с #init_data — иначе теряется email-префилл), добавив
    // в fragment payment_result=<status>. miniApp на старте читает его из
    // Liza.WebApp.initDataUnsafe.payment_result и либо очищает корзину (paid),
    // либо заново открывает её с сохранёнными позициями и данными (cancelled/
    // failed). Через reload JS-колбэк invoiceClosed ненадёжен (closure старой
    // страницы), поэтому статус передаём именно через URL (только статус —
    // полный объект/чек mini app добирает через Liza.WebApp.getInvoice(id) после
    // перезагрузки, чтобы не тащить ПДн чека в URL/историю).
    final base = _resolvedUrl ?? widget.appUrl;
    final invId =
        (result != null ? result['invoice_id'] as int? : null) ?? _currentInvoiceId;
    final invFrag = invId != null ? '&liza_invoice_id=$invId' : '';
    final sep = base.contains('#') ? '&' : '#';
    final returnUrl = '$base${sep}payment_result=$status$invFrag';
    _controller?.loadUrl(
      urlRequest: URLRequest(url: WebUri(returnUrl)),
    );
    _sendInvoiceResult(
      status,
      status == 'paid' ? null : L10n.of(context).miniAppReturnWithoutPayment,
      result,
    );
  }

  void _openExternalLink(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!{'https', 'http', 'mailto', 'tel'}.contains(uri.scheme)) return;

    final l10n = L10n.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.miniAppOpenLinkTitle),
        content: Text(url, maxLines: 3, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              url_launcher.launchUrl(uri);
            },
            child: Text(l10n.open),
          ),
        ],
      ),
    );
  }

  Future<void> _showNativePopup(Map<String, dynamic> params) async {
    final title = params['title'] as String? ?? '';
    final message = params['message'] as String? ?? '';
    final buttons = params['buttons'] as List? ?? [{'type': 'ok'}];
    final l10n = L10n.of(context);

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: title.isNotEmpty ? Text(title) : null,
        content: Text(message),
        actions: [
          for (final btn in buttons)
            if (btn is Map)
              TextButton(
                onPressed: () =>
                    Navigator.of(ctx).pop(btn['id'] ?? btn['type']),
                child: Text(
                  (btn['text'] as String?) ??
                      (btn['type'] == 'cancel' ? l10n.cancel : l10n.ok),
                ),
              ),
        ],
      ),
    );

    _controller?.evaluateJavascript(
      source:
          "Liza.WebApp._receiveEvent('popupClosed', {button_id: ${result != null ? "'$result'" : 'null'}});",
    );
  }

  void _updateMainButton(Map<String, dynamic> data) {
    setState(() {
      if (data['text'] != null) _mainButtonText = data['text'] as String;
      if (data['is_visible'] != null) {
        _mainButtonVisible = data['is_visible'] as bool;
      }
      if (data['is_active'] != null) {
        _mainButtonActive = data['is_active'] as bool;
      }
      if (data['is_progress_visible'] != null) {
        _mainButtonProgress = data['is_progress_visible'] as bool;
      }
      if (data['color'] != null) {
        _mainButtonColor = _parseHexColor(data['color'] as String);
      }
    });
  }

  Color? _parseHexColor(String hex) {
    final clean = hex.replaceFirst('#', '');
    if (clean.length == 6) {
      return Color(int.parse('FF$clean', radix: 16));
    }
    return null;
  }

  void _triggerHaptic(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    switch (type) {
      case 'impact':
        HapticFeedback.mediumImpact();
      case 'notification':
        HapticFeedback.heavyImpact();
      case 'selection_change':
        HapticFeedback.selectionClick();
    }
  }

  Future<void> _closeMiniApp() async {
    if (_needClosingConfirmation) {
      final l10n = L10n.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.miniAppCloseTitle),
          content: Text(l10n.miniAppCloseWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.close),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    widget.onClose();
  }

  void _retry() {
    setState(() {
      _hasError = false;
      _isLoading = true;
      _isReady = false;
    });
    _controller?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    final paymentBarVisible = _isPaymentInProgress && _onPaymentPage;

    final stack = Stack(
      children: [
        // WebView. Непрозрачная белая подложка под ним: webview грузится с
        // transparentBackground:true (нужно мобайлу), и на прозрачных участках
        // страницы (момент загрузки, короткая страница, полоса снизу) сквозь
        // него просвечивал тёмный surface диалога (near-black в тёмной теме) —
        // отсюда «почти чёрный» фон. Белый совпадает с фоном страниц магазина.
        Positioned.fill(
          bottom: _mainButtonVisible
              ? 56 + bottomPadding + viewInsets + 16
              : 0,
          child: _hasError
              ? _buildErrorState(colorScheme)
              : ColoredBox(color: Colors.white, child: _buildWebView()),
        ),

        // Лоадер поверх WebView (до ready)
        if (_isLoading && !_hasError)
          Positioned.fill(
            child: Container(
              color: colorScheme.surface,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      color: colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.appName,
                      style: TextStyle(
                        color: colorScheme.onSurface.withAlpha(153),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // MainButton
        if (_mainButtonVisible)
          Positioned(
            left: 16,
            right: 16,
            bottom: bottomPadding + viewInsets + 8,
            height: 56,
            child: FilledButton(
              onPressed: _mainButtonActive
                  ? () {
                      _controller?.evaluateJavascript(
                        source:
                            "Liza.WebApp._receiveEvent('mainButtonClicked', {});",
                      );
                    }
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor:
                    _mainButtonColor ?? colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    AppConfig.borderRadius,
                  ),
                ),
              ),
              child: _mainButtonProgress
                  ? SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: colorScheme.onPrimary,
                      ),
                    )
                  : Text(
                      _mainButtonText,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
      ],
    );

    // Панель «Вернуться в магазин» — отдельной строкой НАД WebView (Column),
    // а не оверлеем: контент оплаты («Заказ», сумма) не перекрывается и виден
    // без скролла, без пиксельных подгонок офсета.
    //
    // Корень build() ВСЕГДА Column с двумя детьми (слот панели + Expanded с
    // WebView), даже когда панель скрыта. Иначе при переходе корзина→оплата
    // тип корня менялся бы (Stack↔Column), Flutter пересоздавал бы InAppWebView
    // прямо во время навигации на платёжную страницу — отсюда зависание.
    return Column(
      children: [
        if (paymentBarVisible)
          _buildPaymentBar(colorScheme)
        else
          const SizedBox.shrink(),
        Expanded(child: stack),
      ],
    );
  }

  /// Компактная панель оплаты над WebView.
  ///
  /// Без SafeArea (на мобильном лист уже ниже шапки miniApp, на десктопе —
  /// внутри диалога; статус-бар повторно резервировать не нужно) и без крупного
  /// TextButton — иначе занимает слишком много места.
  ///  • До успеха — «Вернуться в магазин»: гарантированный выход с формы / QR
  ///    СБП / страницы рассрочки обратно в корзину (Prodamus своей кнопки в
  ///    WebView не даёт).
  ///  • После success-экрана (_paymentSucceeded) — баннер «Готово» (кнопки
  ///    Prodamus не кликабельны из-за #2147, success инлайн без смены URL).
  Widget _buildPaymentBar(ColorScheme colorScheme) {
    final l10n = L10n.of(context);
    return Material(
      elevation: 2,
      color: colorScheme.surfaceContainerHigh,
      child: _paymentSucceeded
          ? Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.miniAppPaymentDone,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurface.withAlpha(204),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onPressed: () => _returnToShop('paid'),
                    child: Text(l10n.miniAppDone),
                  ),
                ],
              ),
            )
          : InkWell(
              onTap: () => _returnToShop('cancelled'),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.arrow_back,
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      l10n.miniAppBackToStore,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildWebView() {
    if (_resolvedUrl == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(_resolvedUrl!),
      ),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: _bridgePolyfill,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        // Трекер URL: держит _currentUrl свежим на hash-навигации (Tilda-товар).
        UserScript(
          source: _urlTrackerScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        allowFileAccess: false,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        geolocationEnabled: false,
        saveFormData: false,
        // Для стороннего кода запрещаем авто-открытие окон (иначе чужой
        // window.open угоняет навигацию WebView). Нашему app это нужно для
        // платёжного шлюза midget.
        javaScriptCanOpenWindowsAutomatically: !_isThirdParty,
        supportMultipleWindows: !_isThirdParty,
        transparentBackground: true,
        supportZoom: false,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        cacheEnabled: false,
        clearCache: true,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: 'LizaWebAppHandler',
          callback: (args) {
            if (args.isNotEmpty && args.first is String) {
              _handleJsEvent(args.first as String);
            }
          },
        );
        // Актуальный URL страницы (см. _urlTrackerScript) — для захвата
        // deep-link товара при «Скопировать ссылку».
        controller.addJavaScriptHandler(
          handlerName: 'LizaUrlChanged',
          callback: (args) {
            if (args.isNotEmpty && args.first is String) {
              final u = args.first as String;
              if (u.isNotEmpty) _currentUrl = u;
            }
          },
        );
        // Сигнал успеха оплаты со страницы Prodamus (см. _paymentPageScript).
        controller.addJavaScriptHandler(
          handlerName: 'LizaPaymentHandler',
          callback: (args) {
            if (mounted && _isPaymentInProgress) {
              setState(() => _paymentSucceeded = true);
            }
          },
        );
      },
      onUpdateVisitedHistory: (controller, url, isReload) {
        // Tilda меняет только #-фрагмент при выборе товара — onLoadStop на это
        // НЕ срабатывает, а этот колбэк да. Держим _currentUrl свежим для
        // захвата deep-link при «Скопировать ссылку».
        if (url != null) _currentUrl = url.toString();
      },
      onLoadStop: (controller, url) {
        controller.evaluateJavascript(
          source: 'if(window.__lizaBridge) window.__lizaBridge._activate();',
        );
        if (url != null) _currentUrl = url.toString();
        // Надёжно снимаем загрузочный спиннер, когда страница загрузилась — не
        // зависим ТОЛЬКО от web_app_ready (служебный кабинет/чужой app может не
        // вызвать ready() идеально, иначе спиннер крутится вечно).
        if (mounted && _isLoading) {
          setState(() {
            _isLoading = false;
            _isReady = true;
          });
        }
        // third_party: как только shell загрузилась — отдаём ей initData.
        if (_isThirdParty) {
          _provideInitDataToShell();
        }
        // На странице оплаты Prodamus — прячем NPS-опрос и ловим инлайн-успех,
        // а также включаем нативную панель «Вернуться в магазин».
        if (_isPaymentInProgress && _isPaymentHost(url?.host)) {
          controller.evaluateJavascript(source: _paymentPageScript);
          if (!_onPaymentPage && mounted) {
            setState(() => _onPaymentPage = true);
          }
        }
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame == true) {
          setState(() {
            _isLoading = false;
            _hasError = true;
            _errorMessage = error.description;
          });
        }
      },
      onPermissionRequest: (controller, request) async {
        return PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.DENY,
        );
      },
      onCreateWindow: (controller, createWindowAction) async {
        // third_party: чужой window.open игнорируем (могла бы угнать навигацию).
        if (_isThirdParty) {
          return false;
        }
        // Midget (ПФ2) открывает платёжный шлюз банка через window.open().
        // Загружаем этот URL в текущий WebView вместо popup'а.
        final url = createWindowAction.request.url;
        if (url != null) {
          controller.loadUrl(urlRequest: URLRequest(url: url));
        }
        return false;
      },
      shouldOverrideUrlLoading: (controller, action) async {
        final url = action.request.url;
        if (url == null) return NavigationActionPolicy.CANCEL;

        final host = url.host;

        if (url.scheme != 'https') {
          return NavigationActionPolicy.CANCEL;
        }

        // third_party грузится напрямую (shell-host ещё не достроен): навигацию
        // чужого кода держим строго в пределах домена самого app и платёжных
        // хостов Prodamus; любой другой домен (фишинг/угон) — CANCEL.
        if (_isThirdParty) {
          final shellHost = AppConfig.shellHostEnabled
              ? Uri.parse(AppConfig.shellHostBaseUrl).host
              : null;
          if (host == Uri.parse(widget.appUrl).host ||
              _isPaymentHost(host) ||
              (shellHost != null && host == shellHost)) {
            return NavigationActionPolicy.ALLOW;
          }
          return NavigationActionPolicy.CANCEL;
        }

        // Во время оплаты разрешаем навигацию на любой https
        // (банковские 3DS-страницы, платёжные шлюзы и т.д.)
        if (_isPaymentInProgress) {
          return NavigationActionPolicy.ALLOW;
        }

        if (host.endsWith('.prodamus.tech') ||
            host.endsWith('.prodamus.ru') ||
            host.endsWith('payform.online') ||
            host.endsWith('payform.ru') ||
            host == 'securepayform.ru' ||
            host == Uri.parse(widget.appUrl).host ||
            _isPortalHost(host)) {
          return NavigationActionPolicy.ALLOW;
        }

        return NavigationActionPolicy.CANCEL;
      },
      onWebContentProcessDidTerminate: (controller) {
        setState(() {
          _hasError = true;
          _isLoading = false;
          _errorMessage = L10n.of(context).miniAppProcessTerminated;
        });
      },
      onConsoleMessage: (controller, message) {
        // third_party: НЕ пишем тело чужого console в liza.log — чужой код мог
        // бы слить туда PII/токены или использовать наш лог как канал утечки.
        if (_isThirdParty) {
          Logs().d('[MiniApp:${widget.appId}] console (${message.message.length} символов)');
        } else {
          Logs().d('[MiniApp:${widget.appId}] ${message.message}');
        }
      },
    );
  }

  Widget _buildErrorState(ColorScheme colorScheme) {
    final l10n = L10n.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? l10n.miniAppLoadFailed,
              style: TextStyle(
                fontSize: 16,
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: widget.onClose,
                  child: Text(l10n.close),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _retry,
                  child: Text(l10n.retry),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
