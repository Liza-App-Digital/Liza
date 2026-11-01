import 'dart:async';

import 'package:liza/utils/push_report_outbox.dart';

class MemoryPushReportStore implements PushReportStore {
  String? value;
  bool failWrite = false;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    if (failWrite) throw StateError('disk full');
    this.value = value;
  }
}

class CallbackPushReportTransport implements PushReportTransport {
  CallbackPushReportTransport(this.callback, {this.onClose});
  final FutureOr<String?> Function(Map<String, dynamic>) callback;
  final void Function()? onClose;

  @override
  Future<String?> send(Map<String, dynamic> report) async => callback(report);

  @override
  void close() => onClose?.call();
}
