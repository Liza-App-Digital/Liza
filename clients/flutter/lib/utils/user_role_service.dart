import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/utils/custom_http_client.dart';
import 'package:liza/utils/role_view.dart';

class UserRoleService {
  /// Resolves the currently active client. With multi-account, the active
  /// client changes when the user switches accounts - using a callback rather
  /// than a captured reference keeps fetches/role lookups in sync with the
  /// account that's actually being shown.
  final Client Function() activeClient;
  final Map<String, RoleView?> _roleCache = {};
  final Map<String, DateTime> _fetchedAt = {};
  final http.Client _httpClient;

  /// Incremented each time roles are fetched. Listen to this to rebuild UI.
  final ValueNotifier<int> rolesVersion = ValueNotifier(0);

  static const String userRole = 'user';
  static const String aiRole = 'ai';
  static const String developerRole = 'developer';
  static const String moderatorRole = 'moderator';
  static const String adminRole = 'admin';

  /// Localpart'ы настоящих AI-ботов (реально ходят в OpenRouter). Единая точка
  /// правды для показа тега «ИИ»: бейдж рисуется ТОЛЬКО у них. Прочие аккаунты с
  /// ролью `ai` (боты BotFather, служба поддержки, вручную помеченные люди)
  /// держат роль ради поведения (нативные кнопки/карточки), но AI не являются.
  /// Зеркалит серверный `_AI_LOCALPARTS` в модулях Synapse — по localpart, а не
  /// mxid, поэтому одинаково работает на bots.liza.ru / liza.local / dev / компаниях.
  /// Завёл новый AI-инстанс (liza-new-server/liza-company) с новым localpart —
  /// добавь его И сюда, И в серверный `_AI_LOCALPARTS`.
  static const Set<String> realAiLocalparts = {'liza'};

  /// True, если localpart [userId] принадлежит настоящему AI-боту.
  static bool isRealAiLocalpart(String userId) =>
      realAiLocalparts.contains(userId.split(':').first.replaceFirst('@', ''));

  static const String _batchPath = '/_synapse/client/roles/v1/batch';
  static const Duration _requestTimeout = Duration(seconds: 10);
  static const int _maxBatchSize = 100;

  // Микро-маппинг для legacy account_data, в которых сервер не записал role_v2.
  // Используется ТОЛЬКО на переходный период между деплоем бэка и раскаткой
  // нового клиента; удаляется в Phase 3 (отдельный тикет).
  static const Map<String, String> _legacyLabels = {
    'user': 'Пользователь',
    'ai': 'ИИ',
    'developer': 'Разработчик',
    'moderator': 'Модератор',
    'manager': 'Менеджер',
    'admin': 'Администратор',
  };

  UserRoleService(this.activeClient)
      : _httpClient = CustomHttpClient.createHTTPClient();

  bool _isStale(String userId, Duration ttl) {
    final fetched = _fetchedAt[userId];
    if (fetched == null) return true;
    return DateTime.now().difference(fetched) > ttl;
  }

  /// Обрабатывает account_data event для собственного юзера. Префер role_v2
  /// (объект с label/color от сервера); если только legacy string - конвертим
  /// через захардкоженный _legacyLabels на лету.
  void applyOwnAccountData(String userId, Map<String, dynamic> content) {
    // Источник правды доп. ролей — верхнеуровневое поле записи (role_v2 его
    // дублирует, но legacy-записи role_v2 не имеют).
    final extras = RoleView.parseExtraRoles(content['extra_roles']);
    final v2 = content['role_v2'];
    if (v2 is Map<String, dynamic>) {
      final view = RoleView.fromJson(v2);
      _roleCache[userId] = RoleView(
        code: view.code,
        label: view.label,
        color: view.color,
        extraRoles: extras,
      );
      _fetchedAt[userId] = DateTime.now();
      rolesVersion.value++;
      return;
    }
    final raw = content['role'];
    if (raw is String) {
      final label = _legacyLabels[raw];
      _roleCache[userId] = label == null
          ? null
          : RoleView(code: raw, label: label, extraRoles: extras);
      _fetchedAt[userId] = DateTime.now();
      rolesVersion.value++;
    }
  }

  /// Обрабатывает to-device event типа com.liza.user_role.
  /// payload null означает "роль снята".
  void applyToDeviceEvent(String userId, Map<String, dynamic>? payload) {
    if (payload == null) {
      _roleCache[userId] = null;
    } else {
      _roleCache[userId] = RoleView.fromJson(payload);
    }
    _fetchedAt[userId] = DateTime.now();
    rolesVersion.value++;
  }

  /// Удаляет роль [userId] из кэша, чтобы следующий запрос её перезагрузил.
  void invalidate(String userId) {
    _roleCache.remove(userId);
    _fetchedAt.remove(userId);
    rolesVersion.value++;
  }

  /// Обновляет только устаревшие записи из [userIds] (по [ttl]).
  /// Не трогает роли, загруженные свежее [ttl] назад, - экономит HTTP.
  Future<void> refreshIfStale(
    Iterable<String> userIds, {
    Duration ttl = const Duration(minutes: 5),
    Client? client,
  }) async {
    final stale = userIds
        .where((id) => _isStale(id, ttl))
        .take(200)
        .toList();
    if (stale.isEmpty) return;
    await fetchRoles(stale, client: client);
  }

  /// Whether [userId] has the "ai" role (from cache).
  bool isAiUser(String userId) => _roleCache[userId]?.code == aiRole;

  /// Returns cached role for [userId], or null if not loaded.
  RoleView? getRole(String userId) => _roleCache[userId];

  /// Whether [userId] has the "developer" role (main or extra_roles), from
  /// cache. For a freshly logged-in account that is not the active client yet.
  bool isDeveloper(String userId) =>
      _roleCache[userId]?.hasRole(developerRole) ?? false;

  /// Cached role of the currently logged-in user, or null if not yet loaded.
  RoleView? get currentUserRole {
    final id = activeClient().userID;
    if (id == null) return null;
    return _roleCache[id];
  }

  /// Whether the currently logged-in user has the "developer" role - as the
  /// main role or a personal extra role (extra_roles). Returns false when the
  /// role is not yet loaded - safe default that hides developer-only UI.
  bool get isCurrentUserDeveloper =>
      currentUserRole?.hasRole(developerRole) ?? false;

  /// Whether the currently logged-in user has the "admin" role (main or extra).
  /// Returns false when the role is not yet loaded - safe default that hides
  /// admin-only UI for regular users.
  bool get isCurrentUserAdmin => currentUserRole?.hasRole(adminRole) ?? false;

  /// All cached user IDs that have the "ai" role.
  Set<String> get aiUserIds => _roleCache.entries
      .where((e) => e.value?.code == aiRole)
      .map((e) => e.key)
      .toSet();

  /// Fetch roles for [userIds] from the server and cache them.
  ///
  /// Optionally pass [client] to fetch via a specific account (e.g. when
  /// pre-loading a freshly-logged-in client whose role isn't visible from the
  /// previously active account's homeserver). Defaults to the active client.
  Future<void> fetchRoles(
    Iterable<String> userIds, {
    Client? client,
  }) async {
    final c = client ?? activeClient();
    final homeserver = c.homeserver;
    if (homeserver == null || c.accessToken == null) return;

    final ids = userIds.toList();
    if (ids.isEmpty) return;

    // Respect batch size limit
    for (var i = 0; i < ids.length; i += _maxBatchSize) {
      final batch = ids.sublist(
        i,
        min(i + _maxBatchSize, ids.length),
      );
      await _fetchBatch(c, homeserver, batch);
    }
    rolesVersion.value++;
  }

  Future<void> _fetchBatch(
    Client client,
    Uri homeserver,
    List<String> userIds,
  ) async {
    final uri = homeserver.replace(
      path: _batchPath,
      queryParameters: {'v': '2'},
    );
    try {
      final response = await _httpClient
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${client.accessToken}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'user_ids': userIds}),
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final roles = data['roles'] as Map<String, dynamic>?;
        if (roles != null) {
          final now = DateTime.now();
          roles.forEach((userId, raw) {
            if (raw == null) {
              _roleCache[userId] = null;
            } else if (raw is Map<String, dynamic>) {
              _roleCache[userId] = RoleView.fromJson(raw);
            } else if (raw is String) {
              // Legacy server response (no ?v=2 support).
              final label = _legacyLabels[raw];
              _roleCache[userId] = label == null
                  ? null
                  : RoleView(code: raw, label: label);
            }
            _fetchedAt[userId] = now;
          });
          Logs().i('[UserRoleService] Loaded ${roles.length} roles');
        }
      } else {
        Logs().w(
            '[UserRoleService] Batch returned ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      Logs().w('[UserRoleService] Failed to fetch roles batch', e);
    }
  }

  void dispose() {
    _httpClient.close();
  }
}
