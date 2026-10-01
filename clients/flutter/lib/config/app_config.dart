import 'dart:ui';

abstract class AppConfig {
  // Const and final configuration values (immutable)
  static const Color primaryColor = Color(0xFF5625BA);
  static const Color primaryColorLight = Color(0xFFCCBDEA);
  static const Color secondaryColor = Color(0xFF41a2bc);

  static const Color chatColor = primaryColor;
  static const double messageFontSize = 16.0;
  static const bool allowOtherHomeservers = true;
  static const bool enableRegistration = true;
  static const bool hideTypingUsernames = false;

  /// Опросы (poll) временно скрыты из «+»-меню композера (продуктовое решение
  /// 2026-07-17). Функция не удалена — вернуть = выставить `true`. Уже
  /// существующие опросы отрисовываются как прежде; прячем только СОЗДАНИЕ.
  static const bool pollsEnabled = false;

  static const String inviteLinkPrefix = 'https://matrix.to/#/';
  static const String deepLinkPrefix = 'liza://chat/';
  static const String schemePrefix = 'matrix:';
  static const String pushNotificationsChannelId = 'liza_push';

  /// app_id, под которым клиент регистрирует pusher в Sygnal.
  ///
  /// Обязан совпадать с ключом в `apps:` конфига Sygnal и с `topic` APNs.
  /// На Android к нему добавляется суффикс `.data_message`
  /// (см. background_push.dart) — там это отдельный ключ в sygnal.yaml.
  ///
  /// Переопределяется при сборке под другой Apple-аккаунт:
  /// `--dart-define=PUSH_APP_ID=ru.prodamus.liza`.
  static const String pushNotificationsAppId = String.fromEnvironment(
    'PUSH_APP_ID',
    defaultValue: 'ru.prodamus.liza',
  );
  static const double borderRadius = 18.0;
  static const double columnWidth = 360.0;

  /// Сколько файлов уходит за одну отправку (LABA-2621): лишнее диалог
  /// отправки отбрасывает — «Вставить ещё» и пикеры иначе набирали 120+.
  static const int maxAttachmentsPerSend = 30;

  /// Медиа-набор режется на альбомы не длиннее этого — как в Telegram;
  /// альбом из 30 рисовался бы сеткой в 10 рядов.
  static const int albumChunkSize = 10;

  static const String website = 'https://liza.laba.pro';
  static const String faqUrl = 'https://liza.laba.pro/faq';
  static const String appId = 'com.prodamus.laba.liza';
  static const String appOpenUrlScheme = 'liza';

  /// Build environment: "local", "dev" or "prod" (default).
  /// Pass `--dart-define=APP_ENV=dev` (или `=local`) чтобы переключить URL'ы.
  /// `local` — локальный docker-стек (*.liza.local, см. LOCAL-TESTING.md).
  static const String appEnv = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'prod',
  );
  static bool get isDev => appEnv == 'dev';
  static bool get isLocal => appEnv == 'local';

  /// Телефонный вход доступен во всех prod/dev-клиентах; локальный стек
  /// использует пароль и не обращается к внешнему OTP.
  static bool get phoneAuthEnabled => !isLocal;

  static const String versionGateBaseUrl = 'https://versions.tech.liza.ru';

  /// Мониторинг ошибок (Sentry-совместимый бэкенд GlitchTip).
  ///
  /// Выключен по умолчанию: при обычном `flutter run` / hot-reload флаги не
  /// передаются → SDK не инициализируется и не шумит. Включается только для
  /// prod-сборок (CI) и сборок для локального QA-тестирования передачей
  /// build-флагов:
  ///   --dart-define=MONITORING_ENABLED=true
  ///   --dart-define=MONITORING_ENV=prod        (или local-test)
  ///   --dart-define=MONITORING_DSN=`DSN проекта flutter в GlitchTip`
  static const bool monitoringEnabled = bool.fromEnvironment(
    'MONITORING_ENABLED',
    defaultValue: false,
  );
  static const String monitoringEnv = String.fromEnvironment(
    'MONITORING_ENV',
    defaultValue: 'prod',
  );
  static const String monitoringDsn = String.fromEnvironment(
    'MONITORING_DSN',
    defaultValue: '',
  );

  static const String _authProxyProd = 'auth.tech.liza.ru';
  static const String _authProxyDev = 'auth.dev.tech.liza.ru';
  static String get authProxyBaseUrl => isDev ? _authProxyDev : _authProxyProd;

  /// База Liza Bot API (BotFather). Панель BotFather в композере ходит
  /// на `{base}/liza/mybots` (список ботов и mini App владельца). Эмулятор один
  /// (prod-хост); локально — проброшенный порт контейнера liza-bot-api-local.
  static const String _lizaBotApiProd = 'https://bot.tech.liza.ru';
  static const String _lizaBotApiLocal = 'http://localhost:9997';

  /// База Liza Bot API для КОНКРЕТНОГО homeserver активного аккаунта (а не по
  /// APP_ENV): в одном приложении могут быть добавлены и локальный, и prod
  /// аккаунты. Эндпоинт /liza/mybots проверяет токен через whoami на СВОём
  /// homeserver, поэтому base обязан совпадать с homeserver'ом комнаты — иначе
  /// prod-токен уходит в локальный бот и получает 401.
  static String lizaBotApiBaseForHomeserver(String? host) =>
      isLocalHost(host) ? _lizaBotApiLocal : _lizaBotApiProd;

  /// Хост локального стенда (`make local-up`): `*.liza.local`, loopback и
  /// приватный LAN-адрес Mac'а, по которому к стенду ходит физический телефон
  /// (`E2E_HOMESERVER=http://<LAN-IP>:8008`, prove-ui). Единственный предикат
  /// «локальный или прод» для решений ПО КОНКРЕТНОМУ клиенту — режим сборки
  /// (`isLocal`) об аккаунте ничего не говорит: в одном приложении рядом живут
  /// локальный и прод аккаунт.
  static bool isLocalHost(String? host) {
    final h = host ?? '';
    if (h.isEmpty) return false;
    if (h.contains('liza.local') || h == 'localhost' || h == '127.0.0.1') {
      return true;
    }
    return _privateLanIp.hasMatch(h);
  }

  /// RFC 1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
  static final RegExp _privateLanIp = RegExp(
    r'^(10\.\d{1,3}\.\d{1,3}\.\d{1,3}'
    r'|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}'
    r'|192\.168\.\d{1,3}\.\d{1,3})$',
  );

  /// Кабинет разработчика miniApp (визард самообслуживаемого подключения).
  /// Грузится в WebView как служебный first_party-портал.
  static const String _developerPortalProd = 'https://developer.tech.liza.ru';
  static const String _developerPortalLocal = 'https://developer.liza.local';
  // Дев-стенд платформы miniApp погашен (2026-07-22): дев-сборка использует
  // прод-портал, отдельного developer.dev-хоста больше нет.
  static String get developerPortalUrl =>
      isLocal ? _developerPortalLocal : _developerPortalProd;

  /// Базовый URL платёжного модуля mini App (miniapp-store backend).
  ///
  /// Для **third_party**-приложений клиент шлёт `create-invoice`/`status` СЮДА,
  /// а не на домен приложения (`widget.appUrl`): иначе подписанная
  /// `X-Liza-Init-Data` пользователя уходит на сервер разработчика, а он
  /// возвращает произвольный `payment_url`. Явный конфиг-источник вместо резолва
  /// от appUrl. miniapp-store — единое прод-развёртывание (отдельного store-хоста
  /// на dev/local нет; там оплата идёт через MOCK).
  static const String miniAppPaymentBaseUrl = 'https://store.app.tech.liza.ru';

  /// Shell-host: изоляция внешних (third_party) mini App в sandboxed-iframe.
  ///
  /// Пока ВЫКЛЮЧЕН (compile-time флаг) — third_party грузится напрямую и оплата
  /// для него заблокирована (G2). Включается сборкой
  /// `--dart-define=SHELL_HOST_ENABLED=true`, КОГДА shell-host задеплоен и пройден
  /// нативный smoke-тест: тогда third_party грузится через shell (initData —
  /// pull'ом, не в URL), а `openInvoice`/`getInvoice` разблокируются с нативным
  /// confirm. См. plans/miniApps/thirdPartyPaymentUnblock.md (Фаза 1/2).
  static const bool shellHostEnabled = bool.fromEnvironment(
    'SHELL_HOST_ENABLED',
    defaultValue: false,
  );

  /// Оплата из карточки бота (`com.liza.invoice` → кнопка «Оформить»).
  ///
  /// ВКЛЮЧЁН по умолчанию (2026-08-18): прод-цепочка готова — эмулятор постит
  /// подтверждение оплаты (слои A+B), miniapp-store пушит факт paid. Тап «Оформить»
  /// → нативный лист телефона → `BotPaymentWebView` (закрывается на paid, возврат в
  /// чат бота). Переопределяется сборкой `--dart-define=BOT_INVOICE_ENABLED=false`.
  /// Не связан с `shellHostEnabled` (тот гейтит third_party miniApp через shell-host;
  /// bot-путь грузит payment_url напрямую, без shell/iframe-изоляции).
  static const bool botInvoiceEnabled = bool.fromEnvironment(
    'BOT_INVOICE_ENABLED',
    defaultValue: true,
  );
  static const String _shellHostProd = 'https://shell.app.tech.liza.ru';
  // Дев-стенд shell-host погашен (2026-07-22): всегда прод-хост.
  static String get shellHostBaseUrl => _shellHostProd;

  static const String _transcribeProd = 'transcribe.tech.liza.ru';
  static String get transcribeHost => _transcribeProd;

  // Совместимость старого registration callback. В новом интерфейсе
  // регистрация и вход идут через phone/email OTP auth-proxy.
  static const String registrationBaseUrl = 'https://id.prodamus.ru';
  static const String oauthClientId = '52';

  static const String supportUrl = 'https://liza.laba.pro/support';
  static const String changelogUrl = 'https://liza.laba.pro/changelog';

  /// Фолбэк-ссылка формы заявки на доступ (кнопка «Оставить заявку» на экране
  /// входа без инвайта). Version-gate (`VersionGateService.fetchRequestAccessUrl`)
  /// — источник правды и может как обновить, так и явно скрыть кнопку (пустой
  /// ответ сервера). Но пока запрос не завершился (медленная сеть, холодный
  /// старт) или сервис недоступен, пользователь без инвайта не должен видеть
  /// экран без единого релевантного действия — единственная его опция
  /// («Оставить заявку») обязана быть на экране сразу.
  static const String defaultRequestAccessUrl =
      'https://forms.yandex.ru/cloud/6a705487068ff0002aef742d';

  /// Бот службы поддержки Liza для КОНКРЕТНОГО homeserver аккаунта (а не по
  /// APP_ENV): в local-сборке можно войти и в прод-аккаунт, и прод отказывает в
  /// приглашении `@support:liza.local` («Federation denied with liza.local»),
  /// оставляя пустую комнату. Прод и компании — `@support:bots.liza.ru`
  /// (федерация, как @botfather), локальный стенд — `@support:liza.local`.
  /// См. howItWoks/lizaSupport.md.
  static String supportBotMxidForHomeserver(String? host) =>
      isLocalHost(host) ? '@support:liza.local' : '@support:bots.liza.ru';

  static const Set<String> defaultReactions = {'👍', '❤️', '😂', '😮', '😢'};

  static final Uri homeserverList = Uri(
    scheme: 'https',
    host: 'servers.joinmatrix.org',
    path: 'servers.json',
  );

  /// Политика конфиденциальности и Пользовательское соглашение — две разные
  /// страницы (пути `/pp` и `/terms` цитируются самими документами).
  ///
  /// Юрлицо документов — ТОО «Цифровая среда ПРО» (БИН 220340010855). До этой
  /// правки клиент вёл на `liza.ru`, где те же пути отдают документы ООО
  /// «Продамус Лабс» (ИНН 1200019120): домен определяет юрлицо и юрисдикцию,
  /// поэтому менять его — юридическое решение, а не косметика.
  ///
  /// `liza.ru` (`/pp`, `/terms` и хаб `/legal`) обязан остаться живым: на него
  /// продолжают ходить все уже установленные сборки. Сайт живёт в отдельном
  /// репозитории `laba/liza/liza-ru-site` и этой правкой не затрагивается.
  static final Uri privacyUrl = Uri(
    scheme: 'https',
    host: 'liza.cifrapro.kz',
    path: '/pp',
  );

  static final Uri termsUrl = Uri(
    scheme: 'https',
    host: 'liza.cifrapro.kz',
    path: '/terms',
  );

  /// Corresponding Source изменённых компонентов Liza (FluffyChat, Synapse,
  /// Sygnal — все под AGPL-3.0) — публичный монорепозиторий. Отдельные форки
  /// FluffyChat и Synapse в той же организации — чистые копии апстрима без
  /// правок Liza, поэтому как исходник Liza их не показываем.
  static final Uri lizaSourceUrl = Uri.parse(
    'https://github.com/Liza-App-Digital/Liza',
  );

  static const String mainIsolatePortName = 'main_isolate';
  static const String pushIsolatePortName = 'push_isolate';
}
