import 'dart:async';

import 'package:flutter/material.dart';

import 'package:geolocator/geolocator.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';

enum BotContactStatus { granted, denied, unavailable }

class BotContactResult {
  final BotContactStatus status;
  final String? phoneNumber;
  final String? firstName;
  const BotContactResult(this.status, {this.phoneNumber, this.firstName});

  Map<String, dynamic>? get content =>
      status == BotContactStatus.granted && phoneNumber != null
      ? {
          'msgtype': 'm.text',
          'body': '${firstName ?? ''}: $phoneNumber',
          'com.liza.contact': {
            'phone_number': phoneNumber,
            'first_name': firstName ?? '',
          },
        }
      : null;
}

/// Следит за всем запросом, включая получение данных после закрытия диалога.
/// inactive допускает системный запрос разрешения; paused/hidden отменяют запрос.
class _ConsentOperation with WidgetsBindingObserver {
  final BuildContext context;
  final bool Function() isCurrent;
  late final ModalRoute<dynamic>? _route = ModalRoute.of(context);
  late final Timer _timer;
  bool dialogOpen = false;
  bool _cancelled = false;
  _ConsentOperation(this.context, this.isCurrent) {
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => current);
  }
  bool get current {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!context.mounted ||
        !isCurrent() ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.detached ||
        (!dialogOpen && _route != null && !_route.isCurrent)) {
      _cancelled = true;
    }
    return !_cancelled;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _cancelled = true;
    }
  }

  void dispose() {
    _timer.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}

/// Одноразовое согласие. Route удаляется при истечении срока/смене контекста,
/// причём не затрагивает соседние маршруты. Возврат не является отправкой.
Future<T?> showInteractiveConsent<T>({
  required BuildContext context,
  required bool Function() isCurrent,
  required WidgetBuilder builder,
  Duration timeout = const Duration(seconds: 60),
}) async {
  if (!context.mounted || !isCurrent()) return null;
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<T>(context: context, builder: builder);
  final deadline = DateTime.now().add(timeout);
  final timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
    if ((!context.mounted ||
            !isCurrent() ||
            !route.isCurrent ||
            (WidgetsBinding.instance.lifecycleState != null &&
                WidgetsBinding.instance.lifecycleState !=
                    AppLifecycleState.resumed) ||
            DateTime.now().isAfter(deadline)) &&
        route.isActive) {
      navigator.removeRoute(route);
    }
  });
  try {
    final result = await navigator.push(route);
    return context.mounted && isCurrent() && DateTime.now().isBefore(deadline)
        ? result
        : null;
  } finally {
    timer.cancel();
  }
}

Future<BotContactResult> requestBotContact({
  required BuildContext context,
  required Client client,
  required String recipient,
  required bool Function() isCurrent,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final token = client.accessToken;
  final user = client.userID;
  return requestBotContactFromPhones(
    context: context,
    recipient: recipient,
    firstName: user?.localpart ?? '',
    isCurrent: () =>
        isCurrent() && client.accessToken == token && client.userID == user,
    timeout: timeout,
    loadPhones: () => loadBotContactPhones(client),
  );
}

/// Подтверждённые телефонные 3PID. Один источник для native и desktop IPC.
Future<List<String>> loadBotContactPhones(Client client) async =>
    (await client.getAccount3PIDs())
        ?.where((p) => p.medium == ThirdPartyIdentifierMedium.msisdn)
        .map((p) => p.address)
        .toList() ??
    const [];

/// Общий native/desktop диалог. loadPhones вызывается только доверенным host:
/// данные из JavaScript либо bot payload сюда не передаются.
Future<BotContactResult> requestBotContactFromPhones({
  required BuildContext context,
  required String recipient,
  required Future<List<String>> Function() loadPhones,
  required bool Function() isCurrent,
  String firstName = '',
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  final operation = _ConsentOperation(context, isCurrent);
  bool current() => operation.current && DateTime.now().isBefore(deadline);
  try {
    if (!current()) return const BotContactResult(BotContactStatus.denied);
    List<String> loaded;
    try {
      loaded = await loadPhones().timeout(const Duration(seconds: 12));
    } catch (_) {
      return BotContactResult(
        current() ? BotContactStatus.unavailable : BotContactStatus.denied,
      );
    }
    if (!current()) return const BotContactResult(BotContactStatus.denied);
    final phones = loaded
        .where((p) => RegExp(r'^\+?[0-9]{5,20}$').hasMatch(p))
        .toSet()
        .toList();
    if (phones.isEmpty) {
      return const BotContactResult(BotContactStatus.unavailable);
    }
    operation.dialogOpen = true;
    final phone = await showInteractiveConsent<String>(
      context: context,
      isCurrent: current,
      timeout: deadline.difference(DateTime.now()),
      builder: (context) => AlertDialog(
        title: Text(L10n.of(context).botShareContact),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(L10n.of(context).botContactRecipient(recipient)),
              for (final phone in phones)
                ListTile(
                  leading: const Icon(Icons.phone_outlined),
                  title: Text(phone),
                  onTap: () => Navigator.of(context).pop(phone),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(L10n.of(context).cancel),
          ),
        ],
      ),
    );
    operation.dialogOpen = false;
    if (!current() || phone == null || !phones.contains(phone)) {
      return const BotContactResult(BotContactStatus.denied);
    }
    return BotContactResult(
      BotContactStatus.granted,
      phoneNumber: phone,
      firstName: firstName.trim().isEmpty
          ? L10n.of(context).botContact
          : firstName,
    );
  } finally {
    operation.dispose();
  }
}

/// Координаты получаем только после отдельного явного согласия на получателя.
Future<Map<String, dynamic>?> requestBotLocation({
  required BuildContext context,
  required String recipient,
  required bool Function() isCurrent,
}) async {
  final operation = _ConsentOperation(context, isCurrent);
  try {
    if (!operation.current) return null;
    operation.dialogOpen = true;
    final allowed = await showInteractiveConsent<bool>(
      context: context,
      isCurrent: () => operation.current,
      builder: (context) => AlertDialog(
        title: Text(L10n.of(context).botShareLocation),
        content: Text(L10n.of(context).botLocationRecipient(recipient)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.of(context).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.of(context).send),
          ),
        ],
      ),
    );
    operation.dialogOpen = false;
    if (allowed != true || !operation.current) return null;
    try {
      var permission = await Geolocator.checkPermission();
      if (!operation.current) return null;
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever ||
          !operation.current) {
        return null;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 20),
        ),
      );
      if (!operation.current) return null;
      return {
        'msgtype': 'm.location',
        'body':
            'https://www.openstreetmap.org/?mlat=${position.latitude}&mlon=${position.longitude}',
        'geo_uri':
            'geo:${position.latitude},${position.longitude};u=${position.accuracy}',
      };
    } catch (_) {
      return null;
    }
  } finally {
    operation.dispose();
  }
}
