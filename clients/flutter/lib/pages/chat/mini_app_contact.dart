import 'dart:async';

import 'package:flutter/material.dart';

import 'package:liza/pages/chat/mini_app_host_api.dart';
import 'package:liza/utils/bot_interactive_consent.dart';

/// Общий путь native/desktop. Номера ходят только между доверенными Dart-движками;
/// JavaScript получает выбранный номер после конкретного согласия и свежей сверки.
Future<Map<String, dynamic>> requestMiniAppContact({
  required BuildContext context,
  required MiniAppInteractiveHostApi host,
  required String recipient,
  required String documentId,
  required String requestId,
  required bool Function() isCurrent,
}) async {
  final binding = {'document_id': documentId, 'request_id': requestId};
  var hostCurrent = true;
  var checking = false;
  bool current() => hostCurrent && context.mounted && isCurrent();
  final timer = Timer.periodic(const Duration(seconds: 1), (_) async {
    if (checking || !current()) return;
    checking = true;
    try {
      final response = await host.interactiveRequest('check', binding);
      if (response['status'] != 'active') hostCurrent = false;
    } catch (_) {
      hostCurrent = false;
    } finally {
      checking = false;
    }
  });
  try {
    final result = await requestBotContactFromPhones(
      context: context,
      recipient: recipient,
      isCurrent: current,
      loadPhones: () async {
        final result = await host.interactiveRequest('contactPhones', binding);
        final phones = result['phones'];
        return phones is List ? phones.whereType<String>().toList() : const [];
      },
    );
    if (!current()) return {'status': 'denied'};
    if (result.status != BotContactStatus.granted) {
      return {'status': result.status.name};
    }
    final confirmed = await host.interactiveRequest('confirmContact', {
      ...binding,
      'phone_number': result.phoneNumber,
    });
    if (!current()) return {'status': 'denied'};
    return confirmed;
  } catch (_) {
    return {'status': current() ? 'unavailable' : 'denied'};
  } finally {
    timer.cancel();
  }
}
