import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

/// Главное пространство (компания) из федеративного directory.
class CompanyEntry {
  final String roomId;
  final String? name;
  final String? topic;
  final String? avatarUrl;
  final int numJoinedMembers;
  final String? homeserver;
  final List<String> via;

  const CompanyEntry({
    required this.roomId,
    this.name,
    this.topic,
    this.avatarUrl,
    this.numJoinedMembers = 0,
    this.homeserver,
    this.via = const [],
  });

  factory CompanyEntry.fromJson(Map<String, dynamic> json) => CompanyEntry(
    roomId: json['room_id'] as String,
    name: json['name'] as String?,
    topic: json['topic'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    numJoinedMembers: (json['num_joined_members'] as int?) ?? 0,
    homeserver: json['homeserver'] as String?,
    via: (json['via'] as List?)?.map((e) => e.toString()).toList() ?? const [],
  );
}

/// Запрашивает у Synapse-модуля single_space_guard, существует ли главное
/// пространство (root-space) на инстансе, и его room_id.
///
/// Кэширует положительный результат на время сессии: главное пространство
/// неудаляемо, поэтому после exists==true перезапрашивать не нужно.
class SingleSpaceService {
  SingleSpaceService(this.client);

  final Client client;

  bool? _cachedExists;
  String? _cachedRoomId;

  // Кэш: company room_id -> множество роумов-детей этой компании.
  // Заполняется по требованию из getSpaceHierarchy. TTL сессии: hierarchy
  // довольно стабилен, но за минуты меняется; держим 5 минут на запись.
  final Map<String, _CompanyChildrenCache> _companyChildrenCache = {};
  static const _companyChildrenTtl = Duration(minutes: 5);

  // Кэш отрицательных ответов "у этого чата нет родителя-компании".
  // Не дёргаем сеть повторно при каждом открытии чата.
  final Map<String, DateTime> _noParentCache = {};
  static const _noParentTtl = Duration(minutes: 2);

  /// room_id главного пространства или null, если его ещё нет.
  String? get mainRootSpaceId => _cachedRoomId;

  /// Известно ли уже (из кэша), что главное пространство существует.
  bool get knownToExist => _cachedExists == true;

  /// Подтверждено ответом сервера (200), что главного пространства нет. Не то же
  /// самое, что `!knownToExist`: fetch() на сбой отдаёт `exists: false`, ничего
  /// не кэшируя, и такой ответ сюда не попадает.
  bool get knownNotToExist => _cachedExists == false;

  bool _guardDisabled = false;

  bool _isCompanyInstance = false;

  /// Инстанс — компания (поле `company` ответа `/single_space/v1/root`,
  /// = `auto_add_new` модуля `single_space_guard`): все чаты сервера живут в
  /// одном главном пространстве. Общий инстанс (users.liza.ru, bots, стенд) и
  /// старый сервер без поля дают false — поведение приглашений как до
  /// гейта «приглашают только те, кому разрешено» (спека 2026-10-14).
  bool get isCompanyInstance => _isCompanyInstance;

  /// Модуля single_space_guard на сервере нет (локальный стенд): ограничения
  /// «одно главное пространство» нет, создавать пространства можно.
  bool get guardDisabled => _guardDisabled;

  /// Сервер ответил, какого он класса. До ответа (или после сбоя сети)
  /// [isCompanyInstance] = false неотличим от «общий сервер» — потребителям,
  /// для которых это важно (выбор места на «Новой группе»), нужен этот флаг.
  bool get instanceClassKnown => _cachedExists != null || _guardDisabled;

  Future<({bool exists, String? roomId})> fetch() async {
    if (_cachedExists == true) {
      return (exists: true, roomId: _cachedRoomId);
    }
    final homeserver = client.homeserver;
    final accessToken = client.accessToken;
    if (homeserver == null || accessToken == null) {
      return (exists: false, roomId: null);
    }
    try {
      final uri = homeserver.resolve('/_synapse/client/single_space/v1/root');
      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode != 200) {
        // Synapse отвечает 404 M_UNRECOGNIZED на путь незарегистрированного модуля.
        if (response.statusCode == 404 &&
            response.body.contains('M_UNRECOGNIZED')) {
          _guardDisabled = true;
        }
        Logs().w('[SingleSpace] unexpected status ${response.statusCode}');
        return (exists: _cachedExists ?? false, roomId: _cachedRoomId);
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final exists = body['exists'] == true;
      final roomId = body['room_id'] as String?;
      _isCompanyInstance = body['company'] == true;
      _cachedExists = exists;
      _cachedRoomId = roomId;
      return (exists: exists, roomId: roomId);
    } catch (e, s) {
      Logs().w('[SingleSpace] fetch failed', e, s);
      return (exists: _cachedExists ?? false, roomId: _cachedRoomId);
    }
  }

  /// Запрашивает у бэка главные пространства (компании) с фильтром по имени.
  /// Возвращает пустой список при ошибке или закрытой федерации.
  Future<List<CompanyEntry>> fetchCompanies(String query) async {
    final homeserver = client.homeserver;
    final accessToken = client.accessToken;
    if (homeserver == null || accessToken == null) return const [];
    try {
      final uri = homeserver
          .resolve('/_synapse/client/single_space/v1/companies')
          .replace(queryParameters: {'query': query});
      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode != 200) {
        Logs().w('[SingleSpace] companies status ${response.statusCode}');
        return const [];
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final list = (body['companies'] as List?) ?? const [];
      return list
          .map((e) => CompanyEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e, s) {
      Logs().w('[SingleSpace] fetchCompanies failed', e, s);
      return const [];
    }
  }

  /// Найти компанию, чьим ребёнком (m.space.child) является [chatRoomId].
  /// Используется для плашки "подписаться" в чате внешней компании.
  ///
  /// Алгоритм: тянем federation-список компаний (он уже TTL-кэширован на
  /// сервере), для каждой обходим hierarchy (с локальным TTL-кэшом). Возвращает
  /// первую компанию, в дочерних которой есть этот чат, или null.
  Future<CompanyEntry?> findParentCompanyFor(String chatRoomId) async {
    final negativeAt = _noParentCache[chatRoomId];
    if (negativeAt != null &&
        DateTime.now().difference(negativeAt) < _noParentTtl) {
      return null;
    }

    final companies = await fetchCompanies('');
    if (companies.isEmpty) {
      _noParentCache[chatRoomId] = DateTime.now();
      return null;
    }

    for (final company in companies) {
      final children = await _childrenOfCompany(company);
      if (children.contains(chatRoomId)) return company;
    }

    _noParentCache[chatRoomId] = DateTime.now();
    return null;
  }

  Future<Set<String>> _childrenOfCompany(CompanyEntry company) async {
    final cached = _companyChildrenCache[company.roomId];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _companyChildrenTtl) {
      return cached.children;
    }
    try {
      final resp = await client.getSpaceHierarchy(
        company.roomId,
        maxDepth: 1,
        limit: 200,
      );
      final ids = <String>{
        for (final room in resp.rooms)
          if (room.roomId != company.roomId) room.roomId,
      };
      _companyChildrenCache[company.roomId] = _CompanyChildrenCache(ids);
      return ids;
    } catch (e, s) {
      Logs().w('[SingleSpace] hierarchy of ${company.roomId} failed', e, s);
      // Положительный кэш писать опасно: ошибка временная. Не кэшируем.
      return const {};
    }
  }
}

class _CompanyChildrenCache {
  _CompanyChildrenCache(this.children) : at = DateTime.now();
  final Set<String> children;
  final DateTime at;
}
