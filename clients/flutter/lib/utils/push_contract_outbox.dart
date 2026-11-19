import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

const contractPlatformTimeout = Duration(seconds: 2);

typedef ContractJson = Map<String, Object?>;

class ContractEnvelope {
  ContractEnvelope(this.issuer, this.capturedAt, this.proof, this.body);
  final String issuer, proof, body;
  final int capturedAt;
  final _inMemoryAge = Stopwatch()..start();
  int ageMs(int wallNow) =>
      max(_inMemoryAge.elapsedMilliseconds, wallNow - capturedAt) +
      (json['captured_age_ms'] as int);
  late final json = jsonDecode(body) as Map;
  String get id => json['batch_id'] as String;
  bool belongs(String origin, String user, String device) =>
      issuer == origin &&
      json['user_id'] == user &&
      json['device_id'] == device;
  List<Object> get encoded => [issuer, capturedAt, proof, body];
}

/// Отдельная от daily/incident очередь. Любая запись проходит одну общую
/// цепочку, включая purge при logout и новый exporter после reinitialize.
class PushContractOutbox {
  PushContractOutbox({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;
  final Future<SharedPreferences> Function() _preferences;
  String? _persisted, _latestWrite;
  int _latestNow = 0;
  static const key = 'liza.push.contract.queue.v1';
  static final instance = PushContractOutbox();
  static const maxBytes = 256 * 1024;
  static const maxBatches = 32;
  static const ttlMs = 24 * 60 * 60 * 1000;
  Future<void> _serial = Future.value();
  final _items = <ContractEnvelope>[];
  bool _loaded = false;
  int dropped = 0;

  Future<T> _run<T>(int now, T Function() action) {
    _latestNow = now;
    final future = _serial.then((_) async {
      final prefs = await _preferences().timeout(contractPlatformTimeout);
      if (!_loaded) {
        final raw = prefs.getString(key);
        _persisted = raw;
        if (raw != null) {
          try {
            if (utf8.encode(raw).length > maxBytes) {
              throw const FormatException();
            }
            final stored = jsonDecode(raw);
            final records = stored is Map
                ? stored['items'] as List
                : stored as List;
            if (stored is Map) dropped = stored['dropped'] as int;
            for (final record in records.take(maxBatches)) {
              final item = ContractEnvelope(
                record[0] as String,
                record[1] as int,
                record[2] as String,
                record[3] as String,
              );
              if (item.id.isEmpty) throw const FormatException();
              _items.add(item);
            }
          } catch (_) {
            _items.clear();
            dropped++;
          }
        }
        _loaded = true;
      }
      final before = _items.length;
      _items.removeWhere(
        (e) => now < e.capturedAt || now - e.capturedAt >= ttlMs,
      );
      dropped += before - _items.length;
      final result = action();
      String encode() => jsonEncode({
        'dropped': dropped,
        'items': [for (final e in _items) e.encoded],
      });
      var encoded = encode();
      while (_items.length > maxBatches ||
          utf8.encode(encoded).length > maxBytes) {
        _items.removeAt(0);
        dropped++;
        encoded = encode();
      }
      if (_persisted != encoded) {
        _latestWrite = encoded;
        var expired = false;
        final write = prefs.setString(key, encoded).then((success) {
          if (success && expired && _latestWrite != encoded) {
            // Старый backend-write ответил после нового. Восстанавливаем
            // последнюю очередь в её собственной сериализованной линии.
            _persisted = null;
            unawaited(_run(_latestNow, () {}).catchError((_) {}));
          }
          return success;
        });
        try {
          if (!await write.timeout(contractPlatformTimeout)) {
            throw StateError('contract queue unavailable');
          }
          _persisted = encoded;
        } on TimeoutException {
          expired = true;
          _persisted = null;
          rethrow;
        }
      }
      return result;
    });
    _serial = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  Future<bool> add(ContractEnvelope item, int now) => _run(now, () {
    if (utf8.encode(item.body).length > 32768) {
      dropped++;
      return false;
    }
    if (!_items.any((e) => e.id == item.id)) _items.add(item);
    return true;
  });
  Future<ContractEnvelope?> first(
    String origin,
    String user,
    String device,
    int now,
  ) => _run(
    now,
    () => _items.where((e) => e.belongs(origin, user, device)).firstOrNull,
  );
  Future<void> remove(String id, int now) =>
      _run(now, () => _items.removeWhere((e) => e.id == id));
  Future<void> purge(String origin, String user, String device, int now) =>
      _run(
        now,
        () => _items.removeWhere((e) => e.belongs(origin, user, device)),
      );
}
