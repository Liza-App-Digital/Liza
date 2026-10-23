import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/utils/adaptive_bottom_sheet.dart';
import 'package:liza/utils/bot_miniapp_registry.dart';
import 'package:liza/widgets/avatar.dart';

/// Панель BotFather: по кнопке
/// «☰ Меню» в композере открывается оверлей со списком ботов и mini App
/// владельца, поиском и кнопками «Создать бота / Создать mini App». Данные —
/// `GET {lizaBotApiBaseUrl}/liza/mybots` (аутентификация Matrix access-token).
void showBotFatherPanel(BuildContext context, Room room) {
  showAdaptiveBottomSheet(
    context: context,
    builder: (ctx) => BotFatherPanel(room: room),
  );
}

class BotEntry {
  final String mxid;
  final String name;
  final String? username;
  const BotEntry(this.mxid, this.name, this.username);
}

class AppEntry {
  final String name;
  final String? botMxid;
  final String? botName;
  final String? appId;
  final String? appUrl;
  final String appType;
  final String startPath;
  const AppEntry(
    this.name,
    this.botMxid,
    this.botName, {
    this.appId,
    this.appUrl,
    this.appType = 'third_party',
    this.startPath = '',
  });
}

/// Разбор ответа `GET /liza/mybots` в списки для панели. Вынесено из виджета
/// для юнит-тестирования (ledger:RL-botfather-panel-parse): пропускаем ботов
/// без строкового `mxid`; имя бота ← name, иначе mxid; имя app ← name, иначе
/// app_id; терпим отсутствие ключей `bots`/`apps`.
(List<BotEntry>, List<AppEntry>) parseMyBots(Map<String, dynamic> data) {
  final bots = (data['bots'] as List? ?? [])
      .whereType<Map<String, dynamic>>()
      .where((b) => b['mxid'] is String)
      .map(
        (b) => BotEntry(
          b['mxid'] as String,
          (b['name'] as String?)?.trim().isNotEmpty == true
              ? b['name'] as String
              : b['mxid'] as String,
          b['username'] as String?,
        ),
      )
      .toList();
  final apps = (data['apps'] as List? ?? [])
      .whereType<Map<String, dynamic>>()
      .map(
        (a) => AppEntry(
          (a['name'] as String?)?.trim().isNotEmpty == true
              ? a['name'] as String
              : (a['app_id'] as String? ?? 'mini App'),
          a['bot_mxid'] as String?,
          a['bot_name'] as String?,
          appId: a['app_id'] as String?,
          appUrl: (a['app_url'] as String?)?.trim().isNotEmpty == true
              ? a['app_url'] as String
              : null,
          appType: (a['app_type'] as String?)?.trim().isNotEmpty == true
              ? a['app_type'] as String
              : 'third_party',
          startPath: a['app_start_path'] as String? ?? '',
        ),
      )
      .toList();
  return (bots, apps);
}

class BotFatherPanel extends StatefulWidget {
  final Room room;
  const BotFatherPanel({required this.room, super.key});

  @override
  State<BotFatherPanel> createState() => _BotFatherPanelState();
}

class _BotFatherPanelState extends State<BotFatherPanel> {
  // Кэш ответа /liza/mybots по homeserver host — панель открывается мгновенно из
  // последних данных, а сеть догружается в фоне (без спиннера). Живёт на время
  // сессии приложения; обновляется при каждом успешном запросе.
  static final Map<String, (List<BotEntry>, List<AppEntry>)> _cacheByHost = {};

  List<BotEntry> _bots = const [];
  List<AppEntry> _apps = const [];
  bool _loading = true;
  String? _error;
  String? _lastUrl;
  String _query = '';

  // Выбранная строка → экран деталей внутри панели (кнопка «Назад» очищает).
  // Тап по боту или приложению открывает меню действий.
  // по нему. Только одно из полей ненулевое одновременно.
  BotEntry? _selectedBot;
  AppEntry? _selectedApp;

  // Экран привязки приложения к боту (кнопка «Привязать к боту» в _appDetail):
  // поиск + выбор бота из своих. Ненулевое → показываем _attachBotView поверх
  // деталей приложения. Отдельный поисковый запрос, чтобы не смешивать с общим.
  AppEntry? _attachingApp;
  String _attachQuery = '';

  Client get _client => widget.room.client;

  @override
  void initState() {
    super.initState();
    final cached = _cacheByHost[_client.homeserver?.host ?? ''];
    if (cached != null) {
      // Есть кэш → показываем сразу, без спиннера, а сеть догружаем в фоне.
      _bots = cached.$1;
      _apps = cached.$2;
      _loading = false;
      _refresh(silent: true);
    } else {
      _refresh(silent: false);
    }
  }

  /// Запрос за списком ботов/приложений владельца.
  ///
  /// [silent] — фоновое обновление поверх уже показанного кэша: спиннер не
  /// поднимаем, ошибку глотаем (оставляем старые данные на экране). При первом
  /// открытии без кэша — [silent] = false: показываем спиннер и, если запрос
  /// упал, человеческий текст ошибки (кнопки «Повторить» нет — повтор = закрыть
  /// и открыть панель заново).
  Future<void> _refresh({required bool silent}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final host = _client.homeserver?.host ?? '';
    try {
      final base = AppConfig.lizaBotApiBaseForHomeserver(host);
      _lastUrl = '$base/liza/mybots';
      // X-Liza-Homeserver — свой homeserver: BotFather живёт на bots.liza.ru, а
      // аккаунт юзера на своём инстансе; токен валиден только на своём доме, и
      // эндпоинт по этому заголовку шлёт whoami туда (работает для ЛЮБОЙ компании
      // без правок сервера). Сервер валидирует заголовок (только Liza-домены).
      final resp = await http
          .get(
            Uri.parse(_lastUrl!),
            headers: {
              'Authorization': 'Bearer ${_client.accessToken}',
              if (_client.homeserver != null)
                'X-Liza-Homeserver': _client.homeserver!.toString(),
            },
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) {
        Logs().w(
          '[BotFatherPanel] $_lastUrl → ${resp.statusCode}: ${resp.body}',
        );
        throw 'HTTP ${resp.statusCode}';
      }
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final parsed = parseMyBots(data);
      _cacheByHost[host] = parsed;
      if (!mounted) return;
      setState(() {
        _bots = parsed.$1;
        _apps = parsed.$2;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      // Сырой $e и URL — только в лог; пользователю показываем человеческий
      // текст с призывом проверить соединение (частая причина — обрыв связи).
      Logs().w('[BotFatherPanel] load failed ($_lastUrl): $e');
      // Фоновое обновление поверх кэша — тихо оставляем показанные данные.
      if (silent || !mounted) return;
      setState(() {
        _error = L10n.of(context).botFatherLoadFailed;
        _loading = false;
      });
    }
  }

  void _sendCommand(String command) {
    widget.room.sendTextEvent(command, parseCommands: false);
    Navigator.of(context).pop();
  }

  Future<void> _openBot(String mxid) async {
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    try {
      final roomId = await _client.ensureDirectChat(mxid);
      navigator.pop();
      router.go('/rooms/$roomId');
    } catch (e) {
      Logs().e('[BotFatherPanel] open bot failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).miniAppOpenBotChatFailed)),
        );
      }
    }
  }

  /// Открыть mini App прямо из панели (кнопка «Открыть»). Требует `appUrl`
  /// (без него кнопка недоступна). Комната — текущий чат BotFather (панель
  /// открывается только из него, см. isBotFatherRoom в chat_input_row).
  Future<void> _openApp(AppEntry a) async {
    final url = a.appUrl;
    if (url == null) return;
    // open() немодален (miniApp встаёт панелью рядом с чатом) — открываем от
    // контекста чата ПОСЛЕ закрытия панели BotFather.
    final chatContext = Navigator.of(context).context;
    Navigator.of(context).pop();
    await MiniAppWebView.open(
      context: chatContext,
      appUrl: url,
      appId: a.appId ?? 'unknown',
      appName: a.name,
      room: widget.room,
      appType: a.appType,
      appStartPath: a.startPath,
    );
  }

  /// Хэндофф управляющего действия в чат BotFather: шлём боту callback c
  /// `button_id` (тот же контракт, что и кнопки карточек — `_handle_*_callback`
  /// в боте, дедуп по event_id), затем закрываем панель. Готовую карточку
  /// действий рисует бот — переиспользуем существующий функционал, не дублируем.
  Future<void> _handoff(String buttonId, String body) async {
    final navigator = Navigator.of(context);
    try {
      await widget.room.sendEvent({
        'msgtype': 'com.liza.miniapp.callback',
        'body': body,
        'button_id': buttonId,
      });
      // Привязка app к боту меняет /liza/mybots → обновляем реестр, чтобы кнопки
      // «Открыть» у бота появились сразу.
      if (buttonId.startsWith('myapps.attach.pick.')) {
        BotMiniAppRegistry.instance.scheduleRefresh(_client);
      }
    } catch (e) {
      Logs().e('[BotFatherPanel] handoff $buttonId failed: $e');
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    if (_attachingApp != null) return _attachBotView(theme, _attachingApp!);
    if (_selectedBot != null) return _botDetail(theme, _selectedBot!);
    if (_selectedApp != null) return _appDetail(theme, _selectedApp!);
    final q = _query.trim().toLowerCase();
    final bots = q.isEmpty
        ? _bots
        : _bots
              .where(
                (b) =>
                    b.name.toLowerCase().contains(q) ||
                    (b.username ?? '').toLowerCase().contains(q),
              )
              .toList();
    final apps = q.isEmpty
        ? _apps
        : _apps.where((a) => a.name.toLowerCase().contains(q)).toList();

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Шапка: заголовок + закрыть.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Icon(
                  Icons.smart_toy_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('BotFather', style: theme.textTheme.titleLarge),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
            child: Text(
              l10n.botFatherDescription,
              style: theme.textTheme.bodySmall,
            ),
          ),
          // Поиск.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.botFatherSearch,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, style: theme.textTheme.bodyMedium),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      _sectionHeader(theme, l10n.botFatherMyBots),
                      _createRow(
                        theme,
                        l10n.botFatherCreateBot,
                        () => _sendCommand('/newbot'),
                      ),
                      ...bots.map((b) => _botRow(theme, b)),
                      if (_apps.isNotEmpty || q.isEmpty) ...[
                        const SizedBox(height: 8),
                        _sectionHeader(theme, l10n.botFatherMyApps),
                        _createRow(
                          theme,
                          l10n.botFatherCreateApp,
                          () => _sendCommand('/newapp'),
                        ),
                        ...apps.map((a) => _appRow(theme, a)),
                      ],
                      const SizedBox(height: 12),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _createRow(ThemeData theme, String label, VoidCallback onTap) =>
      ListTile(
        leading: Icon(
          Icons.add_circle_outline,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          label,
          style: TextStyle(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        onTap: onTap,
      );

  Widget _botRow(ThemeData theme, BotEntry b) => ListTile(
    leading: FutureBuilder<Profile>(
      future: _client.getProfileFromUserId(b.mxid),
      builder: (context, snap) => Avatar(
        mxContent: snap.data?.avatarUrl,
        name: b.name,
        size: 40,
        client: _client,
      ),
    ),
    title: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: b.username != null
        ? Text('@${b.username}', maxLines: 1, overflow: TextOverflow.ellipsis)
        : null,
    trailing: const Icon(Icons.chevron_right),
    onTap: () => setState(() => _selectedBot = b),
  );

  Widget _appRow(ThemeData theme, AppEntry a) => ListTile(
    leading: CircleAvatar(
      backgroundColor: theme.colorScheme.secondaryContainer,
      child: Icon(
        Icons.widgets_outlined,
        color: theme.colorScheme.onSecondaryContainer,
        size: 20,
      ),
    ),
    title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: a.botName != null
        ? Text(a.botName!, maxLines: 1, overflow: TextOverflow.ellipsis)
        : null,
    trailing: const Icon(Icons.chevron_right),
    onTap: () => setState(() => _selectedApp = a),
  );

  /// Шапка экрана деталей: «← Назад» + название. Возврат очищает выбор —
  /// панель показывает список (предыдущее меню).
  Widget _detailHeader(ThemeData theme, String title, VoidCallback onBack) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: L10n.of(context).botFatherBack,
              onPressed: onBack,
            ),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );

  Widget _actionTile(
    ThemeData theme,
    IconData icon,
    String label,
    VoidCallback? onTap, {
    bool danger = false,
  }) {
    final color = danger ? theme.colorScheme.error : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: color != null ? TextStyle(color: color) : null),
      enabled: onTap != null,
      onTap: onTap,
    );
  }

  /// Меню действий по боту (гибрид: «Открыть» — в клиенте; токен/удаление —
  /// хэндофф карточкой в чат BotFather).
  Widget _botDetail(ThemeData theme, BotEntry b) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _detailHeader(theme, b.name, () => setState(() => _selectedBot = null)),
        if (b.username != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('@${b.username}', style: theme.textTheme.bodySmall),
          ),
        const Divider(height: 1),
        _actionTile(
          theme,
          Icons.chat_outlined,
          L10n.of(context).botFatherOpenBotChat,
          () => _openBot(b.mxid),
        ),
        _actionTile(
          theme,
          Icons.key_outlined,
          L10n.of(context).botFatherShowToken,
          () => _handoff(
            'mybots.token.${b.mxid}',
            L10n.of(context).botFatherTokenBody(b.name),
          ),
        ),
        _actionTile(
          theme,
          Icons.delete_outline,
          L10n.of(context).botFatherDeleteBot,
          () => _handoff(
            'mybots.delete.${b.mxid}',
            L10n.of(context).botFatherDeleteBody(b.name),
          ),
          danger: true,
        ),
        const SizedBox(height: 12),
      ],
    ),
  );

  /// Меню действий по mini App (гибрид: «Открыть» — в клиенте; управление —
  /// хэндофф карточкой `myapps.show.<app_id>` в чат, где уже есть правка/ссылка/
  /// удаление/назад — переиспользуем наш функционал).
  Widget _appDetail(ThemeData theme, AppEntry a) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _detailHeader(theme, a.name, () => setState(() => _selectedApp = null)),
        if (a.botName != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(a.botName!, style: theme.textTheme.bodySmall),
          ),
        const Divider(height: 1),
        _actionTile(
          theme,
          Icons.open_in_new,
          L10n.of(context).botFatherOpenApp,
          a.appUrl != null ? () => _openApp(a) : null,
        ),
        if (a.appId != null)
          _actionTile(
            theme,
            Icons.link,
            a.botName != null
                ? L10n.of(context).botFatherChangeBot
                : L10n.of(context).botFatherAttachToBot,
            () => setState(() {
              _attachingApp = a;
              _attachQuery = '';
            }),
          ),
        if (a.appId != null)
          _actionTile(
            theme,
            Icons.tune,
            L10n.of(context).botFatherAppManage,
            () => _handoff(
              'myapps.show.${a.appId}',
              L10n.of(context).botFatherManageBody(a.name),
            ),
          ),
        const SizedBox(height: 12),
      ],
    ),
  );

  /// Экран привязки приложения к боту: поиск + список своих ботов; тап по боту
  /// привязывает приложение (хэндофф `myapps.attach.pick.<app_id>|<bot_mxid>` —
  /// тот же серверный контракт, что и у карточного пикера в чате). «Назад»
  /// возвращает к деталям приложения.
  Widget _attachBotView(ThemeData theme, AppEntry app) {
    final l10n = L10n.of(context);
    final q = _attachQuery.trim().toLowerCase();
    final bots = q.isEmpty
        ? _bots
        : _bots
              .where(
                (b) =>
                    b.name.toLowerCase().contains(q) ||
                    (b.username ?? '').toLowerCase().contains(q),
              )
              .toList();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _detailHeader(
            theme,
            l10n.botFatherAttachToBot,
            () => setState(() => _attachingApp = null),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l10n.botFatherPickBotForApp(app.name),
              style: theme.textTheme.bodySmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (v) => setState(() => _attachQuery = v),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.botFatherSearchBot,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: bots.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _bots.isEmpty
                          ? l10n.botFatherNoBots
                          : l10n.botFatherBotsNotFound,
                      style: theme.textTheme.bodyMedium,
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: bots
                        .map(
                          (b) => ListTile(
                            leading: FutureBuilder<Profile>(
                              future: _client.getProfileFromUserId(b.mxid),
                              builder: (context, snap) => Avatar(
                                mxContent: snap.data?.avatarUrl,
                                name: b.name,
                                size: 40,
                                client: _client,
                              ),
                            ),
                            title: Text(
                              b.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: b.username != null
                                ? Text(
                                    '@${b.username}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : null,
                            onTap: () => _handoff(
                              'myapps.attach.pick.${app.appId}|${b.mxid}',
                              l10n.botFatherAttachBody(app.name, b.name),
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
