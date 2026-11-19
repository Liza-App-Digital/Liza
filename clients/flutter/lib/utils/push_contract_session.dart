import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/confirmed_read_state.dart';
import 'package:liza/utils/push_contract_outbox.dart';
import 'package:liza/utils/unseen_messages.dart';

String contractFingerprint(Object? fields) =>
    sha256.convert(utf8.encode(jsonEncode(fields))).toString();
String _nonce() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

typedef _Wire = ({
  String? tail,
  int? messages,
  int? highlights,
  bool limited,
  Map<String, String> receipts,
});
typedef ContractCapture = ({ContractEnvelope envelope, List<String> ids});

class PushContractSession {
  static final _bindings = Expando<PushContractSession>();
  static PushContractSession? of(Client client) {
    final s = _bindings[client];
    return s != null && s.valid && s.enabled ? s : null;
  }

  /// До ответа status храним только ограниченный снимок в памяти. Короткое
  /// окно между первым live /sync и включением когорты не теряет raw tail.
  static PushContractSession? observing(Client client) {
    final s = _bindings[client];
    return s != null && s.valid && s._feature != false && s._warmExpiry == null
        ? s
        : null;
  }

  static void warm(Client client) {
    if (_bindings[client]?.valid == true) return;
    final s = PushContractSession(
      client,
      changed: () {},
      isActiveAccount: () => false,
      isPrimaryAccount: () => false,
      lifecycle: () => 'inactive',
      leased: () => true,
    );
    s._warmExpiry = Timer(const Duration(minutes: 2), s.dispose);
  }

  static PushContractSession bind(
    Client client, {
    required void Function() changed,
    required bool Function() isActiveAccount,
    required bool Function() isPrimaryAccount,
    required String Function() lifecycle,
    required bool Function() leased,
    required int Function() clock,
  }) {
    final s = _bindings[client];
    if (s != null && s._warmExpiry != null && s.valid) {
      s._warmExpiry!.cancel();
      s._warmExpiry = null;
      s.changed = changed;
      s.isActiveAccount = isActiveAccount;
      s.isPrimaryAccount = isPrimaryAccount;
      s.lifecycle = lifecycle;
      s.leased = leased;
      // Пассивный bootstrap не предоставляет peer-lease: нужен commit после
      // привязки foreground Matrix. Хвосты отдельных комнат остаются доказаны.
      s.committedAt = null;
      return s;
    }
    return PushContractSession(
      client,
      changed: changed,
      isActiveAccount: isActiveAccount,
      isPrimaryAccount: isPrimaryAccount,
      lifecycle: lifecycle,
      leased: leased,
      clock: clock,
    );
  }

  PushContractSession(
    this.client, {
    required this.changed,
    required this.isActiveAccount,
    required this.isPrimaryAccount,
    required this.lifecycle,
    required this.leased,
    int Function()? clock,
  }) : now = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       user = client.userID!,
       device = client.deviceID!,
       issuer = client.homeserver!.origin {
    _bindings[client] = this;
    _sync = client.onSync.stream.listen(_wire);
    _status = client.onSyncStatus.stream.listen(_barrier);
  }

  final Client client;
  final String user, device, issuer;
  final String epoch = _nonce();
  void Function() changed;
  bool Function() isActiveAccount, isPrimaryAccount, leased;
  String Function() lifecycle;
  final int Function() now;
  late final StreamSubscription _sync, _status;
  Timer? _warmExpiry;
  bool? _feature;
  bool get enabled => _feature == true;
  set enabled(bool value) {
    if (_feature == value) return;
    _feature = value;
    if (!value) {
      suspend();
      _committed.clear();
      _targets.clear();
      _focus.clear();
      _challenges.clear();
    }
  }

  bool disposed = false;
  final _sinceCommit = Stopwatch();
  bool get valid =>
      !disposed &&
      leased() &&
      client.isLogged() &&
      client.userID == user &&
      client.deviceID == device &&
      client.homeserver?.origin == issuer &&
      _bindings[client] == this;
  int syncSequence = 0, revision = 0, _sequence = 0, _cursor = 0, lost = 0;
  int? committedAt;
  int _readSequence = 0, _viewGeneration = 0;
  bool _waiting = false, _processing = false, _clean = false;
  String? _token;
  final _pending = <String, _Wire>{}, _committed = <String, _Wire>{};
  final _leaves = <String>{};
  final _focus = <String>{};
  final _targets = <ContractJson>[];
  final _challenges = <String, ({String value, String fingerprint, int at})>{};
  final frames =
      <
        Object,
        ({String? room, ContractJson data, String? Function() current})
      >{};
  ({ContractJson data, String Function() current})? _badge;
  int _wireLoss = 0;
  bool _lastPartial = false;

  Map<String, String> _ownReceipts(JoinedRoomUpdate room) {
    final out = <String, String>{};
    for (final e in room.ephemeral ?? <BasicEvent>[]) {
      if (e.type != 'm.receipt') continue;
      for (final entry in e.content.entries) {
        final types = entry.value;
        if (types is! Map) continue;
        for (final type in ['m.read', 'm.read.private']) {
          final users = types[type];
          final own = users is Map ? users[user] : null;
          if (own is! Map) continue;
          final thread = own['thread_id'];
          if (thread == null || thread == 'main') {
            out['${thread ?? "unthreaded"}/$type'] = entry.key;
          }
        }
      }
    }
    return out;
  }

  void _wire(SyncUpdate update) {
    if (!valid ||
        _feature == false ||
        !_processing ||
        update.nextBatch.isEmpty) {
      return;
    }
    // SDK отдаёт один live SyncUpdate за транзакцию. Несколько непустых
    // onSync до commit создают неоднозначность (например ручной handleSync).
    if (_token != null) {
      _processing = false;
      _token = null;
      return;
    }
    _token = update.nextBatch;
    _pending.clear();
    _leaves.clear();
    _wireLoss = 0;
    final joined = update.rooms?.join;
    if (joined != null) {
      _wireLoss = max(0, joined.length - 128);
      for (final entry in joined.entries.take(128)) {
        final room = entry.value;
        _pending[entry.key] = (
          tail: room.timeline?.events?.lastOrNull?.eventId,
          messages: room.unreadNotifications?.notificationCount,
          highlights: room.unreadNotifications?.highlightCount,
          limited: room.timeline?.limited == true,
          receipts: _ownReceipts(room),
        );
      }
    }
    if (_wireLoss > 0 && joined != null) {
      // Проведённый ранее wire для пропущенной сейчас комнаты уже недостоверен.
      _leaves.addAll(
        _committed.keys.where(
          (id) => joined.containsKey(id) && !_pending.containsKey(id),
        ),
      );
    }
    final leaves = update.rooms?.leave;
    if (leaves != null) {
      _leaves.addAll(leaves.keys.where(_committed.containsKey));
    }
  }

  void _barrier(SyncStatusUpdate event) {
    if (!valid ||
        _feature == false ||
        (lifecycle() != 'resumed' && lifecycle() != 'inactive')) {
      return;
    }
    switch (event.status) {
      case SyncStatus.waitingForResponse:
        _waiting = true;
        _processing = false;
        _clean = false;
        _token = null;
      case SyncStatus.processing:
        if (_waiting && event.progress == null) _processing = true;
      case SyncStatus.cleaningUp:
        _clean = _processing && _token != null && _token == client.prevBatch;
        _processing = false;
      case SyncStatus.finished:
        if (_clean && _token == client.prevBatch) {
          committedAt = now();
          _sinceCommit
            ..reset()
            ..start();
          syncSequence++;
          if (_pending.isNotEmpty || _leaves.isNotEmpty) revision++;
          for (final id in _leaves) {
            _committed.remove(id);
            _focus.remove(id);
            _challenges.remove(id);
          }
          for (final e in _pending.entries) {
            final previous = _committed.remove(e.key);
            final wire = e.value;
            _committed[e.key] = (
              tail: wire.tail ?? (wire.limited ? null : previous?.tail),
              receipts: {...?previous?.receipts, ...wire.receipts},
              messages: wire.messages,
              highlights: wire.highlights,
              limited:
                  wire.limited ||
                  (previous?.limited == true && wire.tail == null),
            );
            _focus.remove(e.key);
            _focus.add(e.key);
            if (_committed.length > 128) {
              _focus.remove(_committed.keys.first);
              _committed.remove(_committed.keys.first);
              lost++;
            }
          }
          _lastPartial = _wireLoss > 0;
          lost += _wireLoss;
          if (_pending.isNotEmpty || syncSequence == 1) changed();
        }
        _waiting = false;
        _processing = false;
        _clean = false;
        _token = null;
        _pending.clear();
        _leaves.clear();
      case SyncStatus.error:
        _waiting = false;
        _processing = false;
        _clean = false;
        _token = null;
        committedAt = null;
    }
  }

  ContractJson _model(Room room) {
    final w = _committed[room.id];
    final receipts = room.receiptState;
    final global = receipts.global.latestOwnReceipt;
    final own = global != null ? receipts.global : receipts.mainThread;
    final confirmed = ConfirmedReadState.existing(client);
    final unseen = room.unseenWithOverlay(confirmed);
    final scope = global != null ? 'unthreaded' : 'main';
    final receipt = own?.latestOwnReceipt?.eventId;
    final receiptAtTailWithoutWire =
        receipt != null &&
        w?.tail == receipt &&
        w?.receipts['$scope/m.read'] != receipt &&
        w?.receipts['$scope/m.read.private'] != receipt;
    final fields = <String, Object?>{
      'room_id': room.id,
      'tail_event_id': w?.tail,
      'preview_event_id': room.lastEvent?.eventId,
      'receipt_event_id': own?.latestOwnReceipt?.eventId,
      'receipt_scope': global != null
          ? 'unthreaded'
          : own?.latestOwnReceipt != null
          ? 'main'
          : 'unknown',
      'own_public_event_id': own?.ownPublic?.eventId,
      'own_private_event_id': own?.ownPrivate?.eventId,
      'fully_read_event_id': room.fullyRead.isEmpty ? null : room.fullyRead,
      'wire_notification_count': w?.messages,
      'wire_highlight_count': w?.highlights,
      'notification_count': room.notificationCount,
      'highlight_count': room.highlightCount,
      'has_unseen': unseen,
      'counts_toward_badge': room.countsTowardBadgeWith(() => unseen),
      'manual_unread': room.markedUnread,
      'confirmed_read': confirmed?.covers(room) == true,
      'policy': switch (room.pushRuleState) {
        PushRuleState.notify => 'all',
        PushRuleState.mentionsOnly => 'mentions',
        PushRuleState.dontNotify => 'muted',
      },
      'hidden': room.isHiddenChat,
      'encrypted': room.encrypted,
      'limited':
          w == null ||
          w.limited ||
          receiptAtTailWithoutWire ||
          confirmed?.hasUnknownCoverage(room) == true,
    };
    return {
      ...fields,
      'model_fingerprint': contractFingerprint([
        fields,
        room.membership.name,
        room.lastEvent?.type,
        receipts.global.ownPublic?.eventId,
        receipts.global.ownPrivate?.eventId,
        receipts.mainThread?.ownPublic?.eventId,
        receipts.mainThread?.ownPrivate?.eventId,
      ]),
    };
  }

  String? roomFingerprint(Room room) =>
      valid && identical(room, client.getRoomById(room.id))
      ? _model(room)['model_fingerprint'] as String
      : null;

  ({String fingerprint, int count}) aggregate(bool Function(Room)? filter) {
    final scope = <String, bool>{};
    var count = 0;
    for (final room in client.rooms) {
      if (filter != null && !filter(room)) continue;
      final included = room.countsTowardBadgeWith(
        () => room.unseenWithOverlay(ConfirmedReadState.existing(client)),
      );
      scope[room.id] = included;
      if (included) count++;
    }
    final keys = scope.keys.toList()..sort();
    return (
      fingerprint: contractFingerprint([
        user,
        device,
        for (final k in keys) [k, scope[k]],
      ]),
      count: count,
    );
  }

  void recordBadge(int observed, ({String fingerprint, int count}) before) {
    String current() => aggregate(null).fingerprint;
    if (!valid || before.fingerprint != current()) {
      _badge = null;
      return;
    }
    _badge = (
      data: {
        'stage': 'api_result',
        'scope': 'primary',
        'surface_id': 'app_icon',
        'revision': revision,
        'model_fingerprint': before.fingerprint,
        'observed': observed,
        'expected': before.count,
      },
      current: current,
    );
  }

  /// Отпечаток именно HTTP-намерения. Своя receipt и сброс счётчиков
  /// естественно могут примениться до HTTP 200. Пригодность модели для
  /// zero-проверки имеет отдельный полный fingerprint в capture/acknowledge.
  String? readProof(
    Room room, {
    String? rawTail,
    String? scope,
    bool hasGap = false,
  }) {
    final tail = rawTail ?? _committed[room.id]?.tail;
    if (!valid ||
        _feature == false ||
        !isActiveAccount() ||
        tail == null ||
        room.membership != Membership.join ||
        !identical(room, client.getRoomById(room.id))) {
      return null;
    }
    return contractFingerprint([
      epoch,
      _viewGeneration,
      room.id,
      tail,
      scope,
      hasGap,
      room.markedUnread,
      room.pushRuleState.name,
      room.isHiddenChat,
      room.encrypted,
      ConfirmedReadState.existing(client)?.generationOf(room),
    ]);
  }

  void afterReadAck(
    Room room,
    String event,
    String? scope,
    bool full,
    String? before, {
    String? rawTail,
    bool hasGap = false,
  }) {
    if (_feature == false) return;
    final tail = rawTail ?? _committed[room.id]?.tail;
    if (before == null ||
        tail == null ||
        readProof(room, rawTail: tail, scope: scope, hasGap: hasGap) !=
            before) {
      lost++;
      return;
    }
    if (_targets.length >= 8) {
      _targets.removeAt(0);
      lost++;
    }
    _readSequence++;
    _targets.add({
      'room_id': room.id,
      'event_id': event,
      'receipt_scope': scope == null
          ? 'unthreaded'
          : scope == 'main'
          ? 'main'
          : 'unknown',
      'kind': full ? 'full' : 'partial',
      'local_tail': tail,
      'ack_at': now(),
    });
    changed();
  }

  void suspend() {
    committedAt = null;
    _token = null;
    _waiting = _processing = _clean = false;
    _pending.clear();
    invalidateView();
  }

  void invalidateView() {
    _viewGeneration++;
    frames.clear();
    _badge = null;
    revision++;
  }

  void dispose() {
    _warmExpiry?.cancel();
    disposed = true;
    if (_bindings[client] == this) _bindings[client] = null;
    unawaited(_sync.cancel());
    unawaited(_status.cancel());
    frames.clear();
    _badge = null;
  }

  List<String> _sampleIds() {
    final rooms = client.rooms;
    final eligible = {for (final room in rooms) room.id};
    // Архив не входит в live выборку. Не даём восьми уже покинутым комнатам
    // занять все места следующего batch навсегда.
    final before = _targets.length;
    _targets.removeWhere(
      (t) =>
          !eligible.contains(t['room_id']) ||
          now() - (t['ack_at'] as int) > 120000,
    );
    lost += before - _targets.length;
    _challenges.removeWhere((id, _) => !eligible.contains(id));
    _focus.removeWhere((id) => !eligible.contains(id));
    final pinned = <String>{
      ..._targets.map((m) => m['room_id'] as String),
      ..._challenges.keys,
    };
    final ordered = <String>{...pinned};
    final recent = _focus.toList().reversed;
    ordered.addAll(recent.take(4));
    for (var i = 0; i < rooms.length && ordered.length < 8; i++) {
      ordered.add(rooms[(i + _cursor) % rooms.length].id);
    }
    if (rooms.isNotEmpty) _cursor = (_cursor + 4) % rooms.length;
    return ordered
        .where((id) => client.getRoomById(id) != null)
        .take(8)
        .toList();
  }

  ({List<ContractJson> rooms, List<ContractJson> nav, ContractJson? badge})
  _surfaces(List<String> ids) {
    final rows = <String, ContractJson>{}, nav = <ContractJson>[];
    for (final frame in frames.values) {
      final data = frame.data;
      if (!isActiveAccount() ||
          data['revision'] != revision ||
          data['model_fingerprint'] != frame.current()) {
        continue;
      }
      if (frame.room != null) {
        rows[frame.room!] = data;
      } else if (nav.length < 8) {
        nav.add(data);
      }
    }
    final rooms = <ContractJson>[];
    for (final id in ids) {
      final room = client.getRoomById(id);
      if (room == null) continue;
      final model = _model(room);
      final challenge = _challenges[id];
      rooms.add({
        ...model,
        'row': rows[id],
        'challenge':
            challenge != null &&
                now() - challenge.at < 120000 &&
                challenge.fingerprint == model['model_fingerprint']
            ? challenge.value
            : null,
      });
    }
    final b = _badge;
    return (
      rooms: rooms,
      nav: nav,
      badge:
          b != null &&
              isPrimaryAccount() &&
              b.data['revision'] == revision &&
              b.data['model_fingerprint'] == b.current()
          ? b.data
          : null,
    );
  }

  String _proof(List<String> ids) {
    final part = _surfaces(ids);
    return contractFingerprint([
      epoch,
      syncSequence,
      _readSequence,
      revision,
      isActiveAccount(),
      isPrimaryAccount(),
      lifecycle(),
      ConfirmedReadState.existing(client)?.revision.value,
      part.rooms,
      part.nav,
      part.badge,
    ]);
  }

  ContractCapture? capture(
    String platform,
    String build,
    int dropped,
    int accountsOmitted,
  ) {
    if (!valid ||
        !enabled ||
        _processing ||
        _clean ||
        committedAt == null ||
        syncSequence == 0) {
      return null;
    }
    _challenges.removeWhere((_, c) => now() - c.at >= 120000);
    final ids = _sampleIds();
    final part = _surfaces(ids);
    final age = max(_sinceCommit.elapsedMilliseconds, now() - committedAt!);
    final foreground = lifecycle() == 'resumed' || lifecycle() == 'inactive';
    final body = {
      'schema': 1,
      'batch_id': _nonce(),
      'session_id': epoch,
      'sequence': ++_sequence,
      'user_id': user,
      'device_id': device,
      'platform': platform,
      'build': build,
      'lifecycle': lifecycle(),
      'active': foreground,
      'sync_sequence': syncSequence,
      'revision': revision,
      'captured_age_ms': age,
      'rooms': part.rooms,
      'nav': part.nav,
      'badge': part.badge,
      'read_targets': [
        for (final t in _targets)
          for (final r in part.rooms)
            if (r['room_id'] == t['room_id'] &&
                r['tail_event_id'] == t['local_tail'])
              {
                'room_id': t['room_id'],
                'event_id': t['event_id'],
                'receipt_scope': t['receipt_scope'],
                'kind': t['kind'],
                'model_fingerprint': r['model_fingerprint'],
              },
      ],
      'coverage': {
        'live_commit': foreground && age <= 90000,
        'can_observe_receipts': true,
        'partial': _lastPartial,
        'dropped': dropped + lost,
        'rooms_omitted': max(0, client.rooms.length - ids.length),
        'accounts_omitted': accountsOmitted,
      },
    };
    return (
      envelope: ContractEnvelope(issuer, now(), _proof(ids), jsonEncode(body)),
      ids: ids,
    );
  }

  void _deliveredTargets(ContractEnvelope e) {
    final sent = e.json['read_targets'] as List;
    _targets.removeWhere(
      (v) => sent.any(
        (s) => s['room_id'] == v['room_id'] && s['event_id'] == v['event_id'],
      ),
    );
  }

  bool unchanged(ContractEnvelope e) {
    if (!valid ||
        !enabled ||
        _processing ||
        _clean ||
        committedAt == null ||
        e.json['session_id'] != epoch) {
      return false;
    }
    final ids = [
      for (final room in e.json['rooms'] as List) room['room_id'] as String,
    ];
    return _proof(ids) == e.proof;
  }

  bool acknowledge(ContractEnvelope e, Map ack) {
    if (ack['schema'] != 1 ||
        ack['batch_id'] != e.id ||
        ack['accepted'] != true ||
        ack['results'] is! List) {
      return false;
    }
    if (!unchanged(e)) return true;
    // Superseded до POST не теряет доказанную HTTP-цель. Завершаем её лишь
    // после точного ACK от сервера для по-прежнему сопоставимого batch.
    _deliveredTargets(e);
    final models = {
      for (final m in e.json['rooms'] as List)
        m['room_id']: m['model_fingerprint'] as String,
    };
    for (final result in (ack['results'] as List).take(8)) {
      if (result is! Map) continue;
      final id = result['room_id'], challenge = result['challenge'];
      if (id is! String || !models.containsKey(id)) continue;
      if (result['status'] == 'pending' &&
          challenge is String &&
          RegExp(r'^[0-9a-f]{32}$').hasMatch(challenge)) {
        _challenges[id] = (
          value: challenge,
          fingerprint: models[id]!,
          at: now(),
        );
        changed();
      } else {
        _challenges.remove(id);
      }
    }
    return true;
  }
}
