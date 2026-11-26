import 'dart:async';

import 'package:flutter/material.dart';

import 'package:collection/collection.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/settings_integrations/settings_integrations_view.dart';
import 'package:liza/utils/mcp_connections.dart';
import 'package:liza/utils/xl_credentials.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';

/// Витрина MCP-подключений: какие внешние сервисы подключены к Лизе ИИ.
///
/// Раздел исторически назывался «Интеграции» и содержал единственную карточку
/// XL — которая сама и есть MCP-подключение (`xl.py` ходит в MCP-сервер через
/// `shared/mcp_client`). Поэтому витрина не заводится вторым экраном рядом, а
/// расширяет этот: XL — одна из карточек каталога, ВкусВилл — вторая.
class SettingsIntegrationsPage extends StatefulWidget {
  const SettingsIntegrationsPage({super.key});

  @override
  State<SettingsIntegrationsPage> createState() =>
      SettingsIntegrationsController();
}

class SettingsIntegrationsController extends State<SettingsIntegrationsPage> {
  final TextEditingController keyController = TextEditingController();

  /// Карточки, по которым сейчас идёт запись. Тумблер на время операции
  /// блокируется поштучно: в списке из нескольких карточек дабл-тап и
  /// «щёлкнул второй, пока не долетел первый» — реальные сценарии.
  final Set<String> pending = {};

  /// Серверный статус XL из state-event в основном DM с Лизой. Источник
  /// истины — `liza-memory`: она проверяет ключ и пишет событие. Клиент только
  /// читает; `false` до первого ответа (и при отсутствии события).
  bool _serverXlConnected = false;
  bool _serverXlKeySaved = false;
  String _serverXlError = '';

  /// Какая карточка раскрыта ФОРМОЙ ВВОДА КЛЮЧА (у XL подключение — не тумблер).
  ///
  /// Переименовано из `expandedKeyCard`: с появлением второго раскрытия
  /// («Подробнее») имя «Card» стало двусмысленным.
  String? expandedKeyForm;

  /// Какая карточка раскрыта БЛОКОМ ДЕТАЛЕЙ («Подробнее»).
  ///
  /// ⚠️ Отдельное поле, а НЕ режим общего слота. `save()` безусловно гасит
  /// `expandedKeyForm` — при одном слоте сохранение ключа молча схлопнуло бы
  /// инфо-панель. Оси независимы, но взаимно вытесняются (см. ниже), чтобы
  /// карточка не выросла выше экрана при двух открытых блоках.
  String? expandedDetailsCard;

  /// Раскрыть/свернуть детали. Гасит форму ключа: одновременно открыт
  /// максимум один блок.
  void toggleDetails(McpServer server) {
    setState(() {
      expandedDetailsCard = expandedDetailsCard == server.id ? null : server.id;
      if (expandedDetailsCard != null) expandedKeyForm = null;
    });
  }

  /// Подключён ли кабинет XL — только по серверному статусу.
  bool get isConnected => _serverXlConnected;

  /// Ключ сохранён, но не подтверждён (XL недоступен) — кнопка «Отключить» нужна.
  bool get xlKeySaved => _serverXlKeySaved;

  /// Человеческий текст серверной ошибки XL (пусто — ошибки нет).
  String xlErrorText(L10n l10n) {
    switch (_serverXlError) {
      case 'invalid_key':
        return l10n.settingsIntegrationsXlInvalidKey;
      case 'unavailable':
        return _serverXlKeySaved
            ? l10n.settingsIntegrationsXlUnavailable
            : l10n.settingsIntegrationsXlCheckFailed;
      default:
        return _serverXlKeySaved && !_serverXlConnected
            ? l10n.settingsIntegrationsXlUnavailable
            : '';
    }
  }

  /// Основной DM с Лизой ИИ — комната, где живёт state-event с подключениями.
  /// Не первый попавшийся DM с @liza: это мог быть запрос или mini App-чат, а
  /// бот читает подключения из основного (в запросах — тоже из него). Предикат
  /// по m.direct, как у закрепления: member-стейт Лизы в partial-комнате на этом
  /// экране может быть не загружен.
  Room? get lizaRoom => Matrix.of(context).client.rooms.firstWhereOrNull(
    (r) => isLizaAssistantRoom(r, MatrixState.lizaMxid),
  );

  /// Авторитетный набор включённых расширений — спрошенный у СЕРВЕРА.
  /// `null` = ещё не спросили (или спросить не удалось) — тогда показываем
  /// локальный кеш, чтобы не мигать пустотой на первом кадре.
  ///
  /// ⚠️ Поле обязано существовать: полагаться на кеш комнаты и на sync-эхо
  /// здесь нельзя (partial-комната + дедупликация state-события в Synapse —
  /// разбор в докстринге [McpConnections.fetch]).
  Set<String>? _serverEnabled;

  /// Поколение состояния: у [_serverEnabled] ДВА писателя — фоновый
  /// [_refreshEnabled] (стартовый + на каждый релевантный sync) и
  /// оптимистичный [toggle].
  ///
  /// ⚠️ Без этого счётчика они дают гонку «кто ответил последним», и она
  /// воспроизводит ИСХОДНЫЙ симптом другим путём: пользователь жмёт «+»,
  /// карточка становится подключённой, а долетевший следом ответ СТАРОГО GET
  /// (отправленного до записи) возвращает её обратно — со стороны это снова
  /// «плюсик не работает». Поэтому каждый писатель фиксирует поколение перед
  /// `await` и применяет результат, только если оно не устарело.
  int _stateGen = 0;

  StreamSubscription<SyncUpdate>? _syncSub;

  Set<String> get enabled =>
      _serverEnabled ?? McpConnections.readEnabled(lizaRoom);

  bool isEnabled(McpServer server) =>
      server.requiresKey ? isConnected : enabled.contains(server.id);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshXlStatus();
      _refreshEnabled();
      // Правка с другого устройства/ботом: перечитываем авторитетно.
      _syncSub = Matrix.of(context).client.onSync.stream
          .where(McpConnections.syncAffectsConnections)
          .listen((_) {
            _refreshXlStatus();
            _refreshEnabled();
          });
    });
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    keyController.dispose();
    super.dispose();
  }

  Future<void> _refreshEnabled() async {
    final room = lizaRoom;
    if (room == null) return;
    final gen = ++_stateGen;
    final fetched = await McpConnections.fetch(room);
    // `null` = сеть не ответила: сохраняем показанное, а не гасим карточки.
    if (!mounted || fetched == null) return;
    // Пока ответ летел, состояние двинул кто-то ещё (тап пользователя или
    // более свежий фетч) — наш снимок устарел, молча выбрасываем его.
    if (gen != _stateGen) return;
    setState(() => _serverEnabled = fetched);
  }

  /// Серверный статус XL (Bot API → liza-memory). `null` — сеть: показанное не затираем.
  Future<void> _refreshXlStatus() async {
    final info = await XlApi.status(Matrix.of(context).client);
    if (!mounted || info == null) return;
    setState(() {
      _serverXlConnected = info.connected;
      _serverXlKeySaved = info.keySaved;
      _serverXlError = info.error;
    });
  }

  /// Включает/выключает беcключевое расширение (ВкусВилл).
  ///
  /// Пишем state-event в DM с Лизой: то же значение читает бот, поэтому UI и
  /// бот не расходятся и рестарт бота ничего не стирает.
  Future<void> toggle(McpServer server) async {
    if (server.requiresKey) {
      setState(() {
        expandedKeyForm = expandedKeyForm == server.id ? null : server.id;
        // Симметрично toggleDetails: открытая форма гасит детали.
        if (expandedKeyForm != null) expandedDetailsCard = null;
      });
      return;
    }
    if (pending.contains(server.id)) return;

    final room = lizaRoom;
    final l10n = L10n.of(context);
    if (room == null) {
      _snack(l10n.settingsMcpNoLizaChat);
      return;
    }
    // Право проверяем ДО записи: иначе при M_FORBIDDEN тумблер визуально
    // переключился бы, а состояние не сохранилось — молчаливое расхождение.
    if (!McpConnections.canWrite(room)) {
      _snack(l10n.settingsMcpNoPermission);
      return;
    }

    setState(() => pending.add(server.id));
    final next = {...enabled};
    next.contains(server.id) ? next.remove(server.id) : next.add(server.id);
    // Таймаут обязателен: showFutureLoadingDialog модален и без кнопки
    // отмены, а SDK-таймаут межчанковый и измеряется десятками минут —
    // подвисший PUT дал бы нерасторжимый спиннер поверх настроек.
    final result = await showFutureLoadingDialog(
      context: context,
      future: () =>
          McpConnections.write(room, next).timeout(const Duration(seconds: 20)),
    );
    if (!mounted) return;
    if (result.isError) {
      setState(() => pending.remove(server.id));
      return;
    }
    // ⚠️ Состояние двигаем САМИ, а не ждём его обратно из sync. Synapse
    // дедуплицирует state-событие с идентичным содержимым (тот же отправитель
    // + равный canonical-JSON): при расхождении локального кеша с сервером PUT
    // «уже записанного» значения не рождает события, sync молчит — и экран
    // навсегда замирает. Это и был мёртвый плюсик 2026-09-10.
    setState(() {
      pending.remove(server.id);
      // Обесценивает ответы фетчей, стартовавших ДО этой записи: их снимок
      // сервера уже не содержит того, что мы только что записали.
      _stateGen++;
      _serverEnabled = next;
    });
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> save() async {
    final plainKey = keyController.text.trim();
    if (plainKey.isEmpty) return;

    final l10n = L10n.of(context);
    final client = Matrix.of(context).client;
    final result = await showFutureLoadingDialog<XlStatusInfo?>(
      context: context,
      future: () => XlApi.connect(client, plainKey),
    );
    if (!mounted) return;
    if (result.isError) {
      _snack(l10n.settingsIntegrationsXlCheckFailed);
      return;
    }

    final info = result.isValue ? result.asValue!.value : null;
    if (info != null) {
      setState(() {
        _serverXlConnected = info.connected;
        _serverXlKeySaved = info.keySaved;
        _serverXlError = info.error;
      });
    }
    if (info == null || !info.connected) {
      // Сервер не подтвердил ключ: форма остаётся открытой, карточка не врёт.
      final message = info == null
          ? l10n.settingsIntegrationsXlCheckFailed
          : info.error == 'invalid_key'
          ? l10n.settingsIntegrationsXlInvalidKey
          : info.error == 'unavailable' && info.keySaved
          ? l10n.settingsIntegrationsXlUnavailable
          : l10n.settingsIntegrationsXlCheckFailed;
      _snack(message);
      return;
    }

    keyController.clear();
    setState(() => expandedKeyForm = null);
    _snack(l10n.settingsIntegrationsSaved);
  }

  Future<void> disconnect() async {
    final l10n = L10n.of(context);
    final client = Matrix.of(context).client;
    final result = await showFutureLoadingDialog<XlStatusInfo?>(
      context: context,
      future: () => XlApi.connect(client, ''),
    );
    if (!mounted) return;
    if (result.isError) {
      _snack(l10n.settingsIntegrationsXlCheckFailed);
      return;
    }
    final info = result.isValue ? result.asValue!.value : null;
    if (info == null) {
      // Сервер не ответил — не выдаём «отключено» за факт.
      _snack(l10n.settingsIntegrationsXlCheckFailed);
      return;
    }
    setState(() {
      _serverXlConnected = info.connected;
      _serverXlKeySaved = info.keySaved;
      _serverXlError = info.error;
    });
    keyController.clear();
  }

  @override
  Widget build(BuildContext context) => SettingsIntegrationsView(this);
}
