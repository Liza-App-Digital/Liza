import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:matrix/matrix.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:liza/utils/monitoring.dart';

/// Замечает, что macOS-процесс работает старой сборкой, хотя TestFlight уже
/// заменил `Liza.app` на диске.
///
/// Mac пользователя держал процесс 3807 восемь суток, пока на диск приехали
/// 3808…3814. При переходе в окно ОС показывала «Бета-версия «Liza.app» больше
/// не доступна. Профиль обеспечения недействителен» (спека
/// `2026-11-24-macos-stale-process-testflight-design.md`). Связь диалога со
/// старым процессом — гипотеза; событие `[stale-build]` в мониторинге её
/// проверяет по флоту.
///
/// Свой номер — `PackageInfo`: Dart кеширует его на весь процесс, это и есть
/// номер запущенного кода. Номер на диске натив читает из Info.plist заново.
/// Сравнение по `!=`, чтобы откат тоже предлагал выйти.
class MacUpdateChecker {
  MacUpdateChecker({
    bool? enabled,
    Future<String?> Function()? readDiskBuild,
    Future<String> Function()? readRunningBuild,
    DateTime Function()? now,
    void Function(String running, String disk)? onStale,
  }) : enabled = enabled ?? (!kIsWeb && kReleaseMode && Platform.isMacOS),
       _readDiskBuild = readDiskBuild ?? _nativeDiskBuild,
       _readRunningBuild = readRunningBuild ?? _packageBuild,
       _now = now ?? DateTime.now,
       _onStale = onStale ?? _report;

  /// Один на процесс: плашка в списке чатов пересоздаётся при навигации, а
  /// чекер с таймером должен жить, пока жив процесс.
  static final MacUpdateChecker instance = MacUpdateChecker();

  static const MethodChannel channel = MethodChannel('liza/macos_window');

  static const Duration resumeThrottle = Duration(minutes: 15);

  /// Короче, чем у Web: окно в фокусе не получает `resumed`, а диалог ОС
  /// появляется при следующей активации — плашка должна успеть раньше.
  static const Duration pollInterval = Duration(minutes: 10);

  final bool enabled;
  final Future<String?> Function() _readDiskBuild;
  final Future<String> Function() _readRunningBuild;
  final DateTime Function() _now;
  final void Function(String running, String disk) _onStale;

  final ValueNotifier<bool> updateAvailable = ValueNotifier(false);

  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  DateTime? _lastCheck;
  bool _disposed = false;

  void start() {
    if (!enabled || _disposed || _timer != null) return;
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(check()));
    unawaited(check(force: true));
    _timer = Timer.periodic(pollInterval, (_) => check(force: true));
  }

  Future<void> check({bool force = false}) async {
    if (_disposed || !enabled || updateAvailable.value) return;
    final now = _now();
    final last = _lastCheck;
    if (!force && last != null && now.difference(last) < resumeThrottle) {
      return;
    }
    _lastCheck = now;
    final String? disk;
    final String running;
    try {
      disk = await _readDiskBuild().timeout(const Duration(seconds: 5));
      running = await _readRunningBuild();
    } catch (e) {
      Logs().v('MacUpdateChecker: номер сборки не прочитан: $e');
      return;
    }
    if (_disposed || disk == null || disk.isEmpty || running.isEmpty) return;
    if (disk == running) return;
    updateAvailable.value = true;
    _stopPolling();
    _onStale(running, disk);
  }

  static Future<String?> _nativeDiskBuild() =>
      channel.invokeMethod<String>('bundleVersionOnDisk');

  static Future<String> _packageBuild() async =>
      (await PackageInfo.fromPlatform()).buildNumber;

  static void _report(String running, String disk) {
    final title = '[stale-build] running=$running disk=$disk';
    Logs().w(title);
    Monitoring.captureMessage(title);
  }

  static Future<void> quit() async {
    try {
      await channel.invokeMethod<void>('quit');
    } catch (e) {
      Logs().w('MacUpdateChecker: выход не удался: $e');
    }
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  @visibleForTesting
  bool get isPolling => _timer != null;

  void dispose() {
    _disposed = true;
    _stopPolling();
    updateAvailable.dispose();
  }
}
