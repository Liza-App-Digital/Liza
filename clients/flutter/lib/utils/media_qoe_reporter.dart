import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/utils/media_qoe_outbox.dart';
import 'package:liza/utils/media_qoe_session.dart';
import 'package:liza/utils/push_contract_transport.dart';
import 'package:liza/utils/push_journal.dart';

/// Тип сети `connectivity_plus` → закрытый enum сервера.
@visibleForTesting
String mediaQoeNet(List<ConnectivityResult> results) {
  if (results.contains(ConnectivityResult.vpn)) return 'vpn';
  if (results.contains(ConnectivityResult.ethernet)) return 'ethernet';
  if (results.contains(ConnectivityResult.wifi)) return 'wifi';
  if (results.contains(ConnectivityResult.mobile)) return 'mobile';
  if (results.contains(ConnectivityResult.none)) return 'none';
  return results.isEmpty ? 'unknown' : 'other';
}

String _clip(String value, int max) {
  final clean = value.replaceAll(RegExp(r'[\x00-\x1f]'), ' ').trim();
  return clean.length <= max ? clean : clean.substring(0, max);
}

/// Устанавливает [MediaQoeOutbox] приёмником маяка и отправляет накопленное
/// в liza-bot-api (`POST /liza/telemetry/v1/media`) — только на переднем
/// плане, от имени первого аккаунта с доверенным хоумсервером.
class MediaQoeReporter {
  MediaQoeReporter._();
  static final MediaQoeReporter instance = MediaQoeReporter._();

  static const path = '/liza/telemetry/v1/media';

  MediaQoeOutbox? _outbox;
  List<Client> Function()? _clients;
  StreamSubscription<List<ConnectivityResult>>? _net;
  Map<String, Object>? _client;
  Timer? _debounce;

  void start({required List<Client> Function() clients}) {
    _clients = clients;
    if (_outbox != null) return;
    final outbox = MediaQoeOutbox(store: mediaQoeDefaultStore());
    _outbox = outbox;
    MediaQoe.sink = _DrainingSink(outbox, _schedule);
    unawaited(_init(outbox));
  }

  Future<void> _init(MediaQoeOutbox outbox) async {
    try {
      final connectivity = Connectivity();
      MediaQoe.net = mediaQoeNet(await connectivity.checkConnectivity());
      _net = connectivity.onConnectivityChanged.listen(
        (r) => MediaQoe.net = mediaQoeNet(r),
        onError: (Object _) {},
      );
    } catch (_) {}
    try {
      await outbox.load();
      _client = await _clientInfo();
    } catch (_) {}
    _schedule();
  }

  Future<Map<String, Object>> _clientInfo() async {
    final package = await PackageInfo.fromPlatform();
    var os = '';
    var model = '';
    try {
      final info = DeviceInfoPlugin();
      if (kIsWeb) {
        final web = await info.webBrowserInfo;
        os = web.platform ?? '';
        model = web.browserName.name;
      } else {
        final data = (await info.deviceInfo).data;
        os =
            '${data['systemName'] ?? data['osRelease'] ?? data['productName'] ?? ''} '
            '${data['systemVersion'] ?? (data['version'] is Map ? (data['version'] as Map)['release'] : null) ?? data['osVersion'] ?? data['displayVersion'] ?? ''}';
        model =
            '${data['model'] ?? data['modelName'] ?? data['computerName'] ?? ''}';
      }
    } catch (_) {}
    final build = package.buildNumber;
    return {
      'platform': pushReportPlatform(),
      'os': _clip(os, 64),
      'model': _clip(model, 64),
      'build': RegExp(r'^\d{1,12}$').hasMatch(build) ? build : '0',
      'version': _clip(package.version, 32),
    };
  }

  /// Смена жизненного цикла: на переднем плане досылаем накопленное.
  void lifecycleChanged(AppLifecycleState? state) {
    if (state == AppLifecycleState.resumed) _schedule();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 10), () => unawaited(drain()));
  }

  static bool _foreground() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  Future<void> drain() async {
    final outbox = _outbox;
    final client = _client;
    final account = _account();
    if (outbox == null || client == null || account == null) return;
    if (!_foreground() || outbox.pending == 0) return;
    final hs = account.homeserver!;
    final url = Uri.parse(
      '${AppConfig.lizaBotApiBaseForHomeserver(hs.host)}$path',
    );
    await outbox.drain(client, (info, events) async {
      final http.Response response;
      try {
        response = await http
            .post(
              url,
              headers: {
                'Authorization': 'Bearer ${account.accessToken}',
                'X-Liza-Homeserver': hs.origin,
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'schema': 1, 'client': info, 'events': events}),
            )
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        return -1;
      }
      return response.statusCode;
    }, canSend: _foreground);
  }

  Client? _account() {
    for (final c in _clients?.call() ?? const <Client>[]) {
      if (c.isLogged() &&
          c.accessToken != null &&
          PushContractEndpoint.forIssuer(c.homeserver) != null) {
        return c;
      }
    }
    return null;
  }

  @visibleForTesting
  Future<void> stopForTest() async {
    _debounce?.cancel();
    await _net?.cancel();
    _net = null;
    _outbox = null;
    _client = null;
    MediaQoe.sink = null;
  }
}

/// Итог попытки → запись + отложенный drain.
class _DrainingSink implements MediaQoeSink {
  _DrainingSink(this.outbox, this.onFinished);
  final MediaQoeOutbox outbox;
  final void Function() onFinished;

  @override
  void opened(Map<String, Object> event) => outbox.opened(event);

  @override
  void finished(Map<String, Object> event) {
    outbox.finished(event);
    onFinished();
  }

  @override
  void dropped(String attemptId) => outbox.dropped(attemptId);
}
