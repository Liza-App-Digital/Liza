import 'dart:io';
import 'dart:typed_data';

import 'package:matrix/encryption/utils/olm_session.dart';
import 'package:matrix/encryption/utils/outbound_group_session.dart';
import 'package:matrix/encryption/utils/ssss_cache.dart';
import 'package:matrix/encryption/utils/stored_inbound_group_session.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/utils/queued_to_device_event.dart';

/// Обёртка над [DatabaseApi], перехватывающая [PathNotFoundException] И
/// [PathAccessException] в методах файлового кэша.
///
/// matrix SDK 4.1.0 не обрабатывает две TOCTOU-ситуации файл-кэша:
///  1. **ENOENT** ([PathNotFoundException]) — iOS удаляет файлы из
///     Library/Caches/ между `dir.list()` и `file.delete()`.
///  2. **EACCES / errno 32** ([PathAccessException]) — на Windows файл в кэше
///     залочен другим процессом (антивирус, индексатор, Disk Cleanup), и
///     `file.delete()`/`readAsBytes()` падает «файл занят другим процессом».
///     Без этого перехвата исключение всплывает необработанным в root-zone —
///     в логе Петра (Windows) это ~99% строк (шторм `deleteOldFiles` по
///     общему `%TEMP%`). Оба класса — подтипы `FileSystemException` из `dart:io`.
///
/// Удалить после фикса в upstream:
/// https://github.com/famedly/matrix-dart-sdk
class SafeDatabaseApi implements DatabaseApi {
  final DatabaseApi _inner;

  /// Вызывается после `clear()`/`delete()` — так SDK выходит из аккаунта.
  final Future<void> Function()? onWiped;

  SafeDatabaseApi(this._inner, {this.onWiped});

  // -- Методы с патчем -------------------------------------------------------

  @override
  int get maxFileSize => _inner.maxFileSize;

  @override
  bool get supportsFileStoring => _inner.supportsFileStoring;

  @override
  Future<void> deleteOldFiles(int savedAt) async {
    try {
      await _inner.deleteOldFiles(savedAt);
    } on PathNotFoundException catch (e) {
      Logs().w('deleteOldFiles: файл уже удалён ОС', e);
    } on PathAccessException catch (e) {
      // Windows: файл кэша залочен другим процессом (errno 32). Один такой
      // файл прерывает цикл уборки SDK — оставшиеся дочистятся следующим
      // проходом. Здесь важно НЕ дать исключению всплыть в root-zone.
      Logs().w(
        'deleteOldFiles: файл залочен ОС (errno ${e.osError?.errorCode})',
        e,
      );
    }
  }

  @override
  Future<bool> deleteFile(Uri mxcUri) async {
    try {
      return await _inner.deleteFile(mxcUri);
    } on PathNotFoundException catch (_) {
      return false;
    } on PathAccessException catch (e) {
      Logs().w(
        'deleteFile: файл залочен ОС (errno ${e.osError?.errorCode})',
        e,
      );
      return false;
    }
  }

  @override
  Future<Uint8List?> getFile(Uri mxcUri) async {
    try {
      return await _inner.getFile(mxcUri);
    } on PathNotFoundException catch (_) {
      return null;
    } on PathAccessException catch (e) {
      // Чтение из кэша упёрлось в лок — трактуем как cache-miss, вызывающий
      // код перекачает файл заново (иначе тап по медиа молча не откроется).
      Logs().w('getFile: файл залочен ОС (errno ${e.osError?.errorCode})', e);
      return null;
    }
  }

  @override
  Future storeFile(Uri mxcUri, Uint8List bytes, int time) async {
    try {
      return await _inner.storeFile(mxcUri, bytes, time);
    } on PathNotFoundException catch (e) {
      Logs().w('storeFile: директория кэша удалена ОС', e);
    } on PathAccessException catch (e) {
      Logs().w(
        'storeFile: файл/каталог залочен ОС (errno ${e.osError?.errorCode})',
        e,
      );
    }
  }

  // -- Делегирование остальных методов ---------------------------------------

  @override
  Future<Map<String, dynamic>?> getClient(String name) =>
      _inner.getClient(name);

  @override
  Future updateClient(
    String homeserverUrl,
    String token,
    DateTime? tokenExpiresAt,
    String? refreshToken,
    String userId,
    String? deviceId,
    String? deviceName,
    String? prevBatch,
    String? olmAccount,
  ) => _inner.updateClient(
    homeserverUrl,
    token,
    tokenExpiresAt,
    refreshToken,
    userId,
    deviceId,
    deviceName,
    prevBatch,
    olmAccount,
  );

  @override
  Future insertClient(
    String name,
    String homeserverUrl,
    String token,
    DateTime? tokenExpiresAt,
    String? refreshToken,
    String userId,
    String? deviceId,
    String? deviceName,
    String? prevBatch,
    String? olmAccount,
  ) => _inner.insertClient(
    name,
    homeserverUrl,
    token,
    tokenExpiresAt,
    refreshToken,
    userId,
    deviceId,
    deviceName,
    prevBatch,
    olmAccount,
  );

  @override
  Future<List<Room>> getRoomList(Client client) => _inner.getRoomList(client);

  @override
  Future<Room?> getSingleRoom(
    Client client,
    String roomId, {
    bool loadImportantStates = true,
  }) => _inner.getSingleRoom(
    client,
    roomId,
    loadImportantStates: loadImportantStates,
  );

  @override
  Future<Map<String, BasicEvent>> getAccountData() => _inner.getAccountData();

  @override
  Future<void> storeRoomUpdate(
    String roomId,
    SyncRoomUpdate roomUpdate,
    Event? lastEvent,
    Client client,
  ) => _inner.storeRoomUpdate(roomId, roomUpdate, lastEvent, client);

  @override
  Future<void> deleteTimelineForRoom(String roomId) =>
      _inner.deleteTimelineForRoom(roomId);

  @override
  Future<void> storeEventUpdate(
    String roomId,
    StrippedStateEvent event,
    EventUpdateType type,
    Client client,
  ) => _inner.storeEventUpdate(roomId, event, type, client);

  @override
  Future<Event?> getEventById(String eventId, Room room) =>
      _inner.getEventById(eventId, room);

  @override
  Future<void> forgetRoom(String roomId) => _inner.forgetRoom(roomId);

  @override
  Future<CachedProfileInformation?> getUserProfile(String userId) =>
      _inner.getUserProfile(userId);

  @override
  Future<void> storeUserProfile(
    String userId,
    CachedProfileInformation profile,
  ) => _inner.storeUserProfile(userId, profile);

  @override
  Future<void> markUserProfileAsOutdated(String userId) =>
      _inner.markUserProfileAsOutdated(userId);

  @override
  Future<void> clearCache() => _inner.clearCache();

  @override
  Future<void> clear() async {
    await _inner.clear();
    await onWiped?.call();
  }

  @override
  Future<User?> getUser(String userId, Room room) =>
      _inner.getUser(userId, room);

  @override
  Future<List<User>> getUsers(Room room) => _inner.getUsers(room);

  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) => _inner.getEventList(
    room,
    start: start,
    onlySending: onlySending,
    limit: limit,
  );

  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    bool includeSending = false,
    int? limit,
  }) => _inner.getEventIdList(
    room,
    start: start,
    includeSending: includeSending,
    limit: limit,
  );

  @override
  Future storeSyncFilterId(String syncFilterId) =>
      _inner.storeSyncFilterId(syncFilterId);

  @override
  Future storeAccountData(String type, Map<String, Object?> content) =>
      _inner.storeAccountData(type, content);

  @override
  Future storeRoomAccountData(String roomId, BasicEvent event) =>
      _inner.storeRoomAccountData(roomId, event);

  @override
  Future<Map<String, DeviceKeysList>> getUserDeviceKeys(Client client) =>
      _inner.getUserDeviceKeys(client);

  @override
  Future<SSSSCache?> getSSSSCache(String type) => _inner.getSSSSCache(type);

  @override
  Future<OutboundGroupSession?> getOutboundGroupSession(
    String roomId,
    String userId,
  ) => _inner.getOutboundGroupSession(roomId, userId);

  @override
  Future<List<StoredInboundGroupSession>> getAllInboundGroupSessions() =>
      _inner.getAllInboundGroupSessions();

  @override
  Future<StoredInboundGroupSession?> getInboundGroupSession(
    String roomId,
    String sessionId,
  ) => _inner.getInboundGroupSession(roomId, sessionId);

  @override
  Future updateInboundGroupSessionIndexes(
    String indexes,
    String roomId,
    String sessionId,
  ) => _inner.updateInboundGroupSessionIndexes(indexes, roomId, sessionId);

  @override
  Future storeInboundGroupSession(
    String roomId,
    String sessionId,
    String pickle,
    String content,
    String indexes,
    String allowedAtIndex,
    String senderKey,
    String senderClaimedKey,
  ) => _inner.storeInboundGroupSession(
    roomId,
    sessionId,
    pickle,
    content,
    indexes,
    allowedAtIndex,
    senderKey,
    senderClaimedKey,
  );

  @override
  Future markInboundGroupSessionAsUploaded(String roomId, String sessionId) =>
      _inner.markInboundGroupSessionAsUploaded(roomId, sessionId);

  @override
  Future updateInboundGroupSessionAllowedAtIndex(
    String allowedAtIndex,
    String roomId,
    String sessionId,
  ) => _inner.updateInboundGroupSessionAllowedAtIndex(
    allowedAtIndex,
    roomId,
    sessionId,
  );

  @override
  Future removeOutboundGroupSession(String roomId) =>
      _inner.removeOutboundGroupSession(roomId);

  @override
  Future storeOutboundGroupSession(
    String roomId,
    String pickle,
    String deviceIds,
    int creationTime,
  ) =>
      _inner.storeOutboundGroupSession(roomId, pickle, deviceIds, creationTime);

  @override
  Future updateClientKeys(String olmAccount) =>
      _inner.updateClientKeys(olmAccount);

  @override
  Future storeOlmSession(
    String identityKey,
    String sessionId,
    String pickle,
    int lastReceived,
  ) => _inner.storeOlmSession(identityKey, sessionId, pickle, lastReceived);

  @override
  Future setLastActiveUserDeviceKey(
    int lastActive,
    String userId,
    String deviceId,
  ) => _inner.setLastActiveUserDeviceKey(lastActive, userId, deviceId);

  @override
  Future setLastSentMessageUserDeviceKey(
    String lastSentMessage,
    String userId,
    String deviceId,
  ) =>
      _inner.setLastSentMessageUserDeviceKey(lastSentMessage, userId, deviceId);

  @override
  Future clearSSSSCache() => _inner.clearSSSSCache();

  @override
  Future storeSSSSCache(
    String type,
    String keyId,
    String ciphertext,
    String content,
  ) => _inner.storeSSSSCache(type, keyId, ciphertext, content);

  @override
  Future markInboundGroupSessionsAsNeedingUpload() =>
      _inner.markInboundGroupSessionsAsNeedingUpload();

  @override
  Future storePrevBatch(String prevBatch) => _inner.storePrevBatch(prevBatch);

  @override
  Future storeUserDeviceKeysInfo(String userId, bool outdated) =>
      _inner.storeUserDeviceKeysInfo(userId, outdated);

  @override
  Future storeUserDeviceKey(
    String userId,
    String deviceId,
    String content,
    bool verified,
    bool blocked,
    int lastActive,
  ) => _inner.storeUserDeviceKey(
    userId,
    deviceId,
    content,
    verified,
    blocked,
    lastActive,
  );

  @override
  Future removeUserDeviceKey(String userId, String deviceId) =>
      _inner.removeUserDeviceKey(userId, deviceId);

  @override
  Future removeUserCrossSigningKey(String userId, String publicKey) =>
      _inner.removeUserCrossSigningKey(userId, publicKey);

  @override
  Future storeUserCrossSigningKey(
    String userId,
    String publicKey,
    String content,
    bool verified,
    bool blocked,
  ) => _inner.storeUserCrossSigningKey(
    userId,
    publicKey,
    content,
    verified,
    blocked,
  );

  @override
  Future deleteFromToDeviceQueue(int id) => _inner.deleteFromToDeviceQueue(id);

  @override
  Future removeEvent(String eventId, String roomId) =>
      _inner.removeEvent(eventId, roomId);

  @override
  Future setRoomPrevBatch(String? prevBatch, String roomId, Client client) =>
      _inner.setRoomPrevBatch(prevBatch, roomId, client);

  @override
  Future setVerifiedUserCrossSigningKey(
    bool verified,
    String userId,
    String publicKey,
  ) => _inner.setVerifiedUserCrossSigningKey(verified, userId, publicKey);

  @override
  Future setBlockedUserCrossSigningKey(
    bool blocked,
    String userId,
    String publicKey,
  ) => _inner.setBlockedUserCrossSigningKey(blocked, userId, publicKey);

  @override
  Future setVerifiedUserDeviceKey(
    bool verified,
    String userId,
    String deviceId,
  ) => _inner.setVerifiedUserDeviceKey(verified, userId, deviceId);

  @override
  Future setBlockedUserDeviceKey(
    bool blocked,
    String userId,
    String deviceId,
  ) => _inner.setBlockedUserDeviceKey(blocked, userId, deviceId);

  @override
  Future<List<Event>> getUnimportantRoomEventStatesForRoom(
    List<String> events,
    Room room,
  ) => _inner.getUnimportantRoomEventStatesForRoom(events, room);

  @override
  Future<List<OlmSession>> getOlmSessions(String identityKey, String userId) =>
      _inner.getOlmSessions(identityKey, userId);

  @override
  Future<Map<String, Map>> getAllOlmSessions() => _inner.getAllOlmSessions();

  @override
  Future<List<OlmSession>> getOlmSessionsForDevices(
    List<String> identityKeys,
    String userId,
  ) => _inner.getOlmSessionsForDevices(identityKeys, userId);

  @override
  Future<List<QueuedToDeviceEvent>> getToDeviceEventQueue() =>
      _inner.getToDeviceEventQueue();

  @override
  Future insertIntoToDeviceQueue(String type, String txnId, String content) =>
      _inner.insertIntoToDeviceQueue(type, txnId, content);

  @override
  Future<List<String>> getLastSentMessageUserDeviceKey(
    String userId,
    String deviceId,
  ) => _inner.getLastSentMessageUserDeviceKey(userId, deviceId);

  @override
  Future<List<StoredInboundGroupSession>> getInboundGroupSessionsToUpload() =>
      _inner.getInboundGroupSessionsToUpload();

  @override
  Future<void> addSeenDeviceId(
    String userId,
    String deviceId,
    String publicKeys,
  ) => _inner.addSeenDeviceId(userId, deviceId, publicKeys);

  @override
  Future<void> addSeenPublicKey(String publicKey, String deviceId) =>
      _inner.addSeenPublicKey(publicKey, deviceId);

  @override
  Future<String?> deviceIdSeen(String userId, String deviceId) =>
      _inner.deviceIdSeen(userId, deviceId);

  @override
  Future<String?> publicKeySeen(String publicKey) =>
      _inner.publicKeySeen(publicKey);

  @override
  Future<dynamic> close() => _inner.close();

  @override
  Future<void> transaction(Future<void> Function() action) =>
      _inner.transaction(action);

  @override
  Future<String> exportDump() => _inner.exportDump();

  @override
  Future<bool> importDump(String export) => _inner.importDump(export);

  @override
  Future<void> storePresence(String userId, CachedPresence presence) =>
      _inner.storePresence(userId, presence);

  @override
  Future<CachedPresence?> getPresence(String userId) =>
      _inner.getPresence(userId);

  @override
  Future<void> storeWellKnown(DiscoveryInformation? discoveryInformation) =>
      _inner.storeWellKnown(discoveryInformation);

  @override
  Future<DiscoveryInformation?> getWellKnown() => _inner.getWellKnown();

  @override
  Future<void> delete() async {
    await _inner.delete();
    await onWiped?.call();
  }
}
