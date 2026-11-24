import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http show ClientException;
import 'package:matrix/matrix.dart';

import 'package:liza/utils/avatar_stats.dart';

/// Профиль читателя, добытый вне room state.
@immutable
class ReaderProfile {
  final String? displayName;
  final Uri? avatarUrl;
  const ReaderProfile({this.displayName, this.avatarUrl});

  // Равные поля не должны будить слушателей ValueNotifier.
  @override
  bool operator ==(Object other) =>
      other is ReaderProfile &&
      other.displayName == displayName &&
      other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(displayName, avatarUrl);
}

/// Исход одной попытки получить профиль. Закрытое перечисление: идёт в
/// суточный отчёт и в title алёрта, поэтому никаких MXID/текстов ошибок.
enum ReaderProfileOutcome {
  /// Профиль получен, аватарка есть.
  resolved,

  /// Профиль получен, аватарки у человека нет (не дефект).
  noAvatar,

  /// M_NOT_FOUND: профиля нет (ghost, удалён).
  notFound,

  /// M_FORBIDDEN: профиль недоступен нам.
  forbidden,

  /// Невалидный MXID — в сеть не ходили.
  invalid,

  /// Таймаут запроса.
  timeout,

  /// Сетевой сбой клиента (нет связи) — симптом среды, не сервера.
  network,

  /// Ответ сервера вне ожидаемого (5xx, 429, неизвестная ошибка).
  error,
}

/// Догрузка профиля читателя, которого нет в room state.
///
/// Зачем: клиент грузит участников лениво (`lazyLoadMembers`), а читатели из
/// `m.receipt` в lazy-state не попадают — `getReadReceiptsPerMessage` отдаёт для
/// них `User(userId)` без аватарки, и полоска «прочитано до сюда» рисует букву.
/// Резолвер вызывается ТОЛЬКО из виджета аватарки (не из расчёта квитанций, он
/// идёт на каждый rebuild списка — шторм `requestUser`, ae63e039).
///
/// Профили НЕ дублируем: их хранит `Client.getUserProfile` (БД-кэш на сутки,
/// дедуп параллельных запросов, устаревший кэш при сбое сети). Здесь лишь то,
/// чего в SDK нет: отрицательный кэш с TTL (в SDK при отсутствии кэша —
/// `rethrow`, и ghost-id долбил бы сервер на каждый rebuild), потолок
/// параллелизма и подписка виджетов. В room state ничего не пишем.
///
/// Область — один [Client] (мультиаккаунт не смешивается, утечки при выходе
/// нет: резолвер умирает вместе с клиентом).
class ReaderProfileResolver {
  static final Expando<ReaderProfileResolver> _instances = Expando();

  static ReaderProfileResolver of(Client client) =>
      _instances[client] ??= ReaderProfileResolver(client);

  final Client client;
  final int maxParallel;
  final Duration timeout;
  final Duration negativeTtl;
  final int maxEntries;
  final void Function(ReaderProfileOutcome outcome) _onOutcome;
  final DateTime Function() _now;

  ReaderProfileResolver(
    this.client, {
    this.maxParallel = 3,
    this.timeout = const Duration(seconds: 10),
    this.negativeTtl = const Duration(minutes: 10),
    this.maxEntries = 500,
    void Function(ReaderProfileOutcome outcome)? onOutcome,
    DateTime Function()? now,
  }) : _onOutcome = onOutcome ?? AvatarStats.instance.record,
       _now = now ?? DateTime.now {
    _updates = client.onUserProfileUpdate.stream.listen(_onProfileUpdate);
  }

  // Порядок вставки = порядок давности: самый старый вытесняется первым.
  final LinkedHashMap<String, ValueNotifier<ReaderProfile?>> _entries =
      LinkedHashMap();
  final Map<String, DateTime> _retryAfter = {};
  final Map<String, int> _transientFailures = {};
  final Set<String> _inFlight = {};
  final Map<String, Future<void>> _pending = {};
  final Set<String> _rechecked = {};
  final Queue<Completer<void>> _waiters = Queue();
  var _running = 0;
  late final StreamSubscription<String> _updates;

  /// Всего сетевых обращений резолвера (для стража «один запрос на MXID»).
  @visibleForTesting
  var loadCalls = 0;

  /// Живая подписка на профиль. Значение `null` — ещё нет (рисуем букву).
  ValueListenable<ReaderProfile?> watch(String userId) => _entry(userId);

  ValueNotifier<ReaderProfile?> _entry(String userId) {
    final existing = _entries.remove(userId);
    if (existing != null) {
      _entries[userId] = existing;
      return existing;
    }
    final created = ValueNotifier<ReaderProfile?>(null);
    _entries[userId] = created;
    while (_entries.length > maxEntries) {
      final oldest = _entries.keys.first;
      if (_inFlight.contains(oldest)) break;
      _entries.remove(oldest);
      _retryAfter.remove(oldest);
      _transientFailures.remove(oldest);
    }
    return created;
  }

  static bool _valid(String id) =>
      id.isValidMatrixId && id.sigil == '@' && id.localpart!.isNotEmpty;

  /// Запустить догрузку, если она нужна: профиль ещё не получен, нет запроса в
  /// полёте и не действует отрицательный кэш. Идемпотентно — вызывать можно
  /// из `initState` любого числа аватарок.
  void ensure(String userId) {
    final entry = _entry(userId);
    if (entry.value != null || _inFlight.contains(userId)) return;
    final retry = _retryAfter[userId];
    if (retry != null && _now().isBefore(retry)) return;
    if (!_valid(userId)) {
      _retryAfter[userId] = _now().add(negativeTtl);
      _onOutcome(ReaderProfileOutcome.invalid);
      return;
    }
    _inFlight.add(userId);
    unawaited(_pending[userId] = _load(userId, entry));
  }

  /// Профиль «одним Future» для вызывающих, которым нужен результат (лист
  /// «кто прочитал»): тот же запрос, тот же отрицательный кэш, без второго
  /// обращения к сети. `null` — профиля нет (ошибка, 404/403, ещё в паузе).
  Future<ReaderProfile?> fetch(String userId) async {
    ensure(userId);
    final pending = _pending[userId];
    if (pending != null) await pending;
    return _entries[userId]?.value;
  }

  /// Миниатюра аватарки не загрузилась. Возможно, member-событие устарело, а
  /// у человека уже другой `avatar_url`: один раз на пару (userId, URL) за
  /// сессию берём свежий профиль мимо суточного кэша SDK. Перекачки картинки
  /// нет — цикл декода исключён.
  Future<void> recheckAfterThumbFailure(String userId, Uri? failedUrl) async {
    if (!_valid(userId)) return;
    if (!_rechecked.add('$userId|$failedUrl')) return;
    try {
      await _acquire();
      try {
        final profile = await client.getUserProfile(
          userId,
          timeout: timeout,
          maxCacheAge: Duration.zero,
        );
        if (profile.avatarUrl != null && profile.avatarUrl != failedUrl) {
          _entry(userId).value = ReaderProfile(
            displayName: profile.displayname,
            avatarUrl: profile.avatarUrl,
          );
          AvatarStats.instance.recordEvent(AvatarEvent.thumbRecheckChanged);
        }
      } finally {
        _release();
      }
    } catch (_) {
      // Сверка вторична: сбой сети не меняет картинку (остаётся буква).
    }
  }

  void _onProfileUpdate(String userId) {
    final entry = _entries[userId];
    if (entry == null || _inFlight.contains(userId)) return;
    // SDK уже пометил запись устаревшей: следующий getUserProfile пойдёт в сеть.
    _retryAfter.remove(userId);
    _inFlight.add(userId);
    unawaited(_pending[userId] = _load(userId, entry));
  }

  Future<void> _acquire() async {
    if (_running < maxParallel) {
      _running++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _running--;
    }
  }

  Future<void> _load(String userId, ValueNotifier<ReaderProfile?> entry) async {
    ReaderProfileOutcome outcome;
    try {
      await _acquire();
      try {
        loadCalls++;
        final profile = await client.getUserProfile(userId, timeout: timeout);
        entry.value = ReaderProfile(
          displayName: profile.displayname,
          avatarUrl: profile.avatarUrl,
        );
        _transientFailures.remove(userId);
        _retryAfter.remove(userId);
        outcome = profile.avatarUrl == null
            ? ReaderProfileOutcome.noAvatar
            : ReaderProfileOutcome.resolved;
      } finally {
        _release();
      }
    } on MatrixException catch (e) {
      outcome = switch (e.errcode) {
        'M_NOT_FOUND' => ReaderProfileOutcome.notFound,
        'M_FORBIDDEN' => ReaderProfileOutcome.forbidden,
        _ => ReaderProfileOutcome.error,
      };
    } on TimeoutException {
      outcome = ReaderProfileOutcome.timeout;
    } on SocketException {
      outcome = ReaderProfileOutcome.network;
    } on http.ClientException {
      outcome = ReaderProfileOutcome.network;
    } catch (_) {
      outcome = ReaderProfileOutcome.error;
    } finally {
      _inFlight.remove(userId);
      _pending.remove(userId);
    }

    switch (outcome) {
      case ReaderProfileOutcome.notFound:
      case ReaderProfileOutcome.forbidden:
        _retryAfter[userId] = _now().add(negativeTtl);
      case ReaderProfileOutcome.timeout:
      case ReaderProfileOutcome.network:
      case ReaderProfileOutcome.error:
        // Временный сбой: повтор с нарастающей паузой 30 с … 5 мин.
        final failures = (_transientFailures[userId] ?? 0) + 1;
        _transientFailures[userId] = failures;
        final seconds = (30 * (1 << (failures - 1).clamp(0, 4))).clamp(30, 300);
        _retryAfter[userId] = _now().add(Duration(seconds: seconds));
      case ReaderProfileOutcome.resolved:
      case ReaderProfileOutcome.noAvatar:
      case ReaderProfileOutcome.invalid:
        break;
    }
    _onOutcome(outcome);
  }

  @visibleForTesting
  Future<void> dispose() => _updates.cancel();
}
