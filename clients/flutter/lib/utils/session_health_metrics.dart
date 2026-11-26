import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/monitoring.dart';

/// Нулевой уровень для стоп-крана обновления matrix SDK
/// (`howItWoks/CheckListToDo/updateMatrix/01-plan.md` §4): разлогины по причине
/// и доля сообщений, не расшифрованных при получении. Без этой недели замеров
/// на старом SDK ступени обновления не с чем сравнивать.
enum LogoutReason {
  user('user'),
  unknownToken('unknown_token'),
  other('other');

  const LogoutReason(this.wire);
  final String wire;
}

/// Разлогин — только переход из loggedIn в loggedOut. loggedOut без
/// предшествующего входа (холодный старт без сессии) разлогином не считается.
@visibleForTesting
LogoutReason? classifyLogout({
  required LoginState? previous,
  required LoginState next,
  required bool explicit,
  required bool unknownTokenSeen,
}) {
  if (next != LoginState.loggedOut || previous != LoginState.loggedIn) {
    return null;
  }
  if (explicit) return LogoutReason.user;
  if (unknownTokenSeen) return LogoutReason.unknownToken;
  return LogoutReason.other;
}

enum E2eeArrival { plain, decrypted, undecryptable }

/// Состояние события из таймлайна синка: SDK пытается расшифровать до выдачи в
/// `onTimelineEvent`, неудача оставляет тип `m.room.encrypted`. Меряем именно
/// «при получении»: поздний ключ это значение не меняет, поэтому сборки
/// сравнимы между собой.
@visibleForTesting
E2eeArrival classifyArrival(Event event) {
  if (event.type == EventTypes.Encrypted) return E2eeArrival.undecryptable;
  if (event.originalSource?.type == EventTypes.Encrypted) {
    return E2eeArrival.decrypted;
  }
  return E2eeArrival.plain;
}

class SessionHealthMetrics {
  SessionHealthMetrics._();

  static const String receivedKey = 'health.e2ee_received';
  static const String utdKey = 'health.e2ee_utd';

  static final Map<String, LoginState> _lastState = {};
  static final Set<String> _unknownTokenSeen = {};
  static final Map<String, List<StreamSubscription>> _subs = {};

  static int _pendingReceived = 0;
  static int _pendingUtd = 0;
  static Timer? _flushTimer;

  /// Подписка на клиента основного изолята. Повторный вызов для того же
  /// клиента ничего не делает.
  static void attach(Client client) {
    final name = client.clientName;
    if (_subs.containsKey(name)) return;
    _lastState[name] = client.onLoginStateChanged.value ?? LoginState.loggedOut;
    _subs[name] = [
      client.onSyncStatus.stream.listen((update) {
        final error = update.error?.exception;
        if (error is MatrixException &&
            error.error == MatrixError.M_UNKNOWN_TOKEN) {
          _unknownTokenSeen.add(name);
        }
      }),
      client.onTimelineEvent.stream.listen((event) {
        switch (classifyArrival(event)) {
          case E2eeArrival.plain:
            return;
          case E2eeArrival.decrypted:
            _pendingReceived++;
          case E2eeArrival.undecryptable:
            _pendingReceived++;
            _pendingUtd++;
        }
        _flushTimer ??= Timer(const Duration(seconds: 30), flush);
      }),
    ];
  }

  /// Звать из обработчика смены состояния входа. [explicit] — пользователь сам
  /// нажал «Выйти» / удалил аккаунт.
  static void noteLoginState(
    Client client,
    LoginState state, {
    required bool explicit,
  }) {
    final name = client.clientName;
    final reason = classifyLogout(
      previous: _lastState[name],
      next: state,
      explicit: explicit,
      unknownTokenSeen: _unknownTokenSeen.contains(name),
    );
    _lastState[name] = state;
    if (state == LoginState.loggedIn) _unknownTokenSeen.remove(name);
    if (reason == null) return;
    _unknownTokenSeen.remove(name);
    Monitoring.reportSessionLogout(reason.wire);
    for (final sub in _subs.remove(name) ?? const <StreamSubscription>[]) {
      unawaited(sub.cancel());
    }
  }

  static Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pendingReceived == 0) return;
    final received = _pendingReceived;
    final utd = _pendingUtd;
    _pendingReceived = 0;
    _pendingUtd = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        receivedKey,
        (prefs.getInt(receivedKey) ?? 0) + received,
      );
      await prefs.setInt(utdKey, (prefs.getInt(utdKey) ?? 0) + utd);
    } catch (_) {
      // Метрика не критична: потеря одной порции лучше сбоя на синке.
    }
  }

  /// Забирает накопленное с прошлого heartbeat и обнуляет счётчики.
  static Future<({int received, int utd})> take(SharedPreferences prefs) async {
    final received = prefs.getInt(receivedKey) ?? 0;
    final utd = prefs.getInt(utdKey) ?? 0;
    await prefs.remove(receivedKey);
    await prefs.remove(utdKey);
    return (received: received, utd: utd);
  }

  @visibleForTesting
  static void resetForTest() {
    _lastState.clear();
    _unknownTokenSeen.clear();
    _subs.clear();
    _pendingReceived = 0;
    _pendingUtd = 0;
    _flushTimer?.cancel();
    _flushTimer = null;
  }
}
