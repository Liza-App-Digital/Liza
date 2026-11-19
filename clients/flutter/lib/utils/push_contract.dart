import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/push_contract_outbox.dart';
import 'package:liza/utils/push_contract_session.dart';
import 'package:liza/utils/push_contract_transport.dart';

class _Account {
  _Account(this.session, this.base);
  final PushContractSession session;
  final Uri base;
  int due = 0, allowed = 0;
  bool revoked = false;
}

class PushContractScheduler {
  PushContractScheduler({
    required this.clients,
    required this.active,
    required this.lifecycle,
    PushContractTransport? network,
    PushContractOutbox? queue,
    int Function()? clock,
    Uri? Function(Uri?)? endpoint,
    Future<String> Function()? build,
  }) : transport = network ?? PushContractTransport(),
       outbox = queue ?? PushContractOutbox.instance,
       now = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       endpoint = endpoint ?? PushContractEndpoint.forIssuer,
       build =
           build ??
           (() async => (await PackageInfo.fromPlatform()).buildNumber);
  final List<Client> Function() clients;
  final Client? Function() active;
  final String Function() lifecycle;
  final PushContractTransport transport;
  final PushContractOutbox outbox;
  final int Function() now;
  final Uri? Function(Uri?) endpoint;
  final Future<String> Function() build;
  final _accounts = <Client, _Account>{};
  final _flags = <Uri, ({bool? enabled, int until})>{};
  // Бюджет принадлежит установке, в том числе при reinitializeClients().
  static const budgetKey = 'liza.push.contract.request_window.v1';
  static final _requests = <int>[];
  Timer? _timer;
  int _cursor = 0;
  bool _disposed = false, _busy = false;
  String? _build;
  bool get _foreground => lifecycle() == 'resumed' || lifecycle() == 'inactive';

  /// Начало foreground init бывает раньше mount Matrix. SDK посылает loggedIn
  /// перед запуском первого /sync. Фоновые изоляты сюда не подписываются.
  static void beforeForegroundInit(Client client) {
    late final StreamSubscription<LoginState> sub;
    Timer? timer;
    void stop() {
      unawaited(sub.cancel());
      timer?.cancel();
    }

    sub = client.onLoginStateChanged.stream.listen(
      (event) {
        if (event != LoginState.loggedIn) return;
        stop();
        if (PushContractEndpoint.forIssuer(client.homeserver) != null &&
            client.userID != null &&
            client.deviceID != null) {
          PushContractSession.warm(client);
        }
      },
      onError: (Object _, StackTrace _) {
        // initWithRestore сам обрабатывает ошибку и может повторить login.
      },
      onDone: () => timer?.cancel(),
    );
    timer = Timer(const Duration(minutes: 2), stop);
  }

  void attach(Client c, {bool renewed = false}) {
    if (_disposed) return;
    final existing = _accounts[c];
    if (existing != null &&
        existing.session.valid &&
        !(renewed && existing.revoked)) {
      return;
    }
    if (existing != null) detach(c);
    final base = endpoint(c.homeserver);
    if (base == null ||
        !c.isLogged() ||
        c.deviceID?.isNotEmpty != true ||
        c.userID?.isNotEmpty != true ||
        _accounts.length >= 16) {
      return;
    }
    final s = PushContractSession.bind(
      c,
      changed: () => mark(c),
      isActiveAccount: () => identical(active(), c),
      isPrimaryAccount: () => identical(clients().firstOrNull, c),
      lifecycle: lifecycle,
      clock: now,
      leased: () => !_disposed && clients().contains(c),
    );
    _accounts[c] = _Account(s, base)..due = now() + 2000;
    _arm();
  }

  void detach(Client c, {bool logout = false}) {
    final account = _accounts.remove(c);
    if (account == null) return;
    final s = account.session;
    s.dispose();
    if (logout) {
      unawaited(
        outbox.purge(s.issuer, s.user, s.device, now()).catchError((_) {}),
      );
    }
  }

  void viewChanged() {
    for (final a in _accounts.values) {
      a.session.invalidateView();
      mark(a.session.client);
    }
  }

  void lifecycleChanged() {
    if (!_foreground) {
      transport.cancel();
      _timer?.cancel();
      for (final a in _accounts.values) {
        a.session.suspend();
      }
    } else {
      viewChanged();
      _arm();
    }
  }

  void mark(Client c) {
    final a = _accounts[c];
    if (a == null || a.revoked) return;
    a.due = min(a.due, now() + 2000);
    _arm();
  }

  void _pruneRequests() {
    final cut = now() - 60000;
    _requests.removeWhere((t) => t <= cut || t > now());
  }

  Future<bool> _spend() async {
    final prefs = await SharedPreferences.getInstance().timeout(
      contractPlatformTimeout,
    );
    final stamp = now();
    // Резерв до HTTP переживает перезапуск процесса. В установке отправляет
    // только основной UI isolate. Перевод часов назад не раздаёт новый бюджет.
    final persisted = prefs.getStringList(budgetKey) ?? const [];
    _requests
      ..clear()
      ..addAll(
        persisted
            .take(8)
            .map((s) => min(int.tryParse(s) ?? stamp, stamp))
            .where((t) => t > stamp - 60000),
      )
      ..sort();
    final allowed = _requests.length < 8;
    if (allowed) _requests.add(stamp);
    final saved = await prefs
        .setStringList(budgetKey, [for (final t in _requests) '$t'])
        .timeout(contractPlatformTimeout);
    return allowed && saved;
  }

  void _arm() {
    if (_disposed || _busy || !_foreground) return;
    _timer?.cancel();
    final live = _accounts.values.where((a) => !a.revoked && a.session.valid);
    if (live.isEmpty) return;
    _pruneRequests();
    var when = live.map((a) => max(a.due, a.allowed)).reduce(min);
    if (_requests.length >= 8) when = max(when, _requests.first + 60000);
    _timer = Timer(
      Duration(milliseconds: max(1, when - now())),
      () => unawaited(_tick()),
    );
  }

  @visibleForTesting
  Future<void> runDue() => _tick();

  Future<void> _tick() async {
    if (_disposed || _busy || !_foreground) return;
    _pruneRequests();
    if (_requests.length >= 8) {
      _arm();
      return;
    }
    final accounts = _accounts.values.toList();
    for (var i = 0; i < accounts.length; i++) {
      final index = (_cursor + i) % accounts.length;
      final a = accounts[index];
      if (a.revoked || !a.session.valid || max(a.due, a.allowed) > now()) {
        continue;
      }
      _cursor = (index + 1) % accounts.length;
      _busy = true;
      a.due = now() + 60000;
      a.allowed = now() + 15000;
      try {
        await _submit(a);
      } catch (_) {
        /* Ошибка транспорта/хранилища — batch остаётся в очереди. */
      } finally {
        _busy = false;
      }
      break;
    }
    _arm();
  }

  bool _usable(_Account a) =>
      !_disposed &&
      _foreground &&
      a.session.valid &&
      identical(_accounts[a.session.client], a);
  Future<void> _submit(_Account a) async {
    final s = a.session;
    var flag = _flags[a.base];
    if (flag == null || flag.until <= now()) {
      if (!await _spend() || !_usable(a)) return;
      final resp = await transport.request(a.base.resolve('status'));
      if (!_usable(a)) return;
      final reported = resp.data['contract'];
      final cohort = resp.status == 200 && reported is bool ? reported : null;
      flag = (
        enabled: cohort,
        until: now() + (cohort == null ? 60000 : 300000),
      );
      _flags[a.base] = flag;
    }
    final enabled = flag.enabled;
    // Ошибка источника не является решением выключить когорту. Сохраняем
    // bounded live evidence, но не посылаем его до успешного status.
    if (enabled != null) s.enabled = enabled;
    if (enabled != true) {
      a.due = flag.until;
      return;
    }
    _build ??= await build().timeout(contractPlatformTimeout);
    if (!_usable(a)) return;
    if (!RegExp(r'^[0-9]+(?:\.[0-9]+)*$').hasMatch(_build!)) return;
    final platform = kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase();
    if (platform == 'fuchsia') return;
    final capture = s.capture(
      platform,
      _build!,
      outbox.dropped,
      max(0, clients().where((c) => c.isLogged()).length - _accounts.length),
    );
    var saved = false;
    if (capture != null) {
      saved = await outbox.add(capture.envelope, now());
      if (!_usable(a)) return;
    }
    var e = await outbox.first(s.issuer, s.user, s.device, now());
    if (!_usable(a) || e == null) return;
    int age(ContractEnvelope item) => item.ageMs(now());
    // Свежесть не переносится между сессиями/моделями. Старый offline batch
    // может ехать как история только с действительным возрастом >90 секунд.
    if (!s.unchanged(e) && age(e) <= 90000) {
      await outbox.remove(e.id, now());
      s.lost++;
      if (!_usable(a) ||
          capture == null ||
          !saved ||
          !s.unchanged(capture.envelope) ||
          e.id == capture.envelope.id) {
        return;
      }
      e = capture.envelope;
    }
    if (!await _spend()) {
      a.due = now() + 2000;
      return;
    }
    if (!_usable(a) || (age(e) <= 90000 && !s.unchanged(e))) return;
    // Достаём токен ПОСЛЕ последнего await, только у этого же живого Client.
    final token = s.client.accessToken;
    if (token == null || token.isEmpty) return;
    final response = await transport.request(
      a.base.resolve('contract'),
      issuer: s.issuer,
      token: token,
      body: e.body,
      ageMs: age(e),
    );
    if (!_usable(a)) return;
    if (s.client.accessToken != token) {
      mark(s.client);
      return;
    }
    if (response.status == 401 || response.status == 403) {
      a.revoked = true;
      s.enabled = false;
      await outbox.purge(s.issuer, s.user, s.device, now());
      return;
    }
    if (response.status == 429 || response.status == 503) {
      a.allowed = max(a.allowed, now() + response.retry.clamp(1, 3600) * 1000);
      return;
    }
    if (response.status == 200 && s.acknowledge(e, response.data)) {
      final retry = response.data['retry_after_ms'];
      if (retry is int) {
        a.allowed = max(a.allowed, now() + retry.clamp(0, 3600000));
      }
      await outbox.remove(e.id, now());
      return;
    }
    if ([400, 409, 413, 422].contains(response.status)) {
      s.lost++;
      await outbox.remove(e.id, now());
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    transport.cancel();
    for (final a in _accounts.values) {
      a.session.dispose();
    }
    _accounts.clear();
  }
}
