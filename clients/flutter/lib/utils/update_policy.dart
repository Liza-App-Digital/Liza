import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Поэтапное обязательное обновление. Этап считает version-gate
/// (`GET /policy`), клиент только показывает и помнит, что пользователь уже
/// видел/отложил. Карта — howItWoks/lizaUpdates.md.
enum UpdateStage { none, recommended, announce, soft, hard }

class UpdatePolicy {
  const UpdatePolicy({
    required this.stage,
    this.build,
    this.latestBuild,
    this.latestVersion,
    this.updateUrl,
    this.announceAt,
    this.softAt,
    this.deadlineAt,
    this.serverNow,
    this.maxPostpones = 3,
    this.softIntervalH = 24,
    this.bannerIntervalH = 72,
    this.readOnlyEnabled = true,
  });

  final UpdateStage stage;
  final int? build;
  final int? latestBuild;
  final String? latestVersion;
  final String? updateUrl;
  final DateTime? announceAt;
  final DateTime? softAt;
  final DateTime? deadlineAt;
  final DateTime? serverNow;
  final int maxPostpones;
  final int softIntervalH;
  final int bannerIntervalH;
  final bool readOnlyEnabled;

  static const none = UpdatePolicy(stage: UpdateStage.none);

  bool get readOnly => stage == UpdateStage.hard && readOnlyEnabled;

  static DateTime? _date(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

  static UpdatePolicy fromJson(Map<String, dynamic> json) {
    final stage =
        UpdateStage.values.where((s) => s.name == json['stage']).firstOrNull ??
        UpdateStage.none;
    return UpdatePolicy(
      stage: stage,
      build: (json['build'] as num?)?.toInt(),
      latestBuild: (json['latest_build'] as num?)?.toInt(),
      latestVersion: json['latest_version'] as String?,
      updateUrl: json['update_url'] as String?,
      announceAt: _date(json['announce_at']),
      softAt: _date(json['soft_at']),
      deadlineAt: _date(json['deadline_at']),
      serverNow: _date(json['server_now']),
      maxPostpones: (json['max_postpones'] as num?)?.toInt() ?? 3,
      softIntervalH: (json['soft_interval_h'] as num?)?.toInt() ?? 24,
      bannerIntervalH: (json['banner_interval_h'] as num?)?.toInt() ?? 72,
      readOnlyEnabled: json['read_only_enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'stage': stage.name,
    'build': build,
    'latest_build': latestBuild,
    'latest_version': latestVersion,
    'update_url': updateUrl,
    'announce_at': announceAt?.toIso8601String(),
    'soft_at': softAt?.toIso8601String(),
    'deadline_at': deadlineAt?.toIso8601String(),
    'server_now': serverNow?.toIso8601String(),
    'max_postpones': maxPostpones,
    'soft_interval_h': softIntervalH,
    'banner_interval_h': bannerIntervalH,
    'read_only_enabled': readOnlyEnabled,
  };

  UpdatePolicy withStage(UpdateStage newStage) => UpdatePolicy(
    stage: newStage,
    build: build,
    latestBuild: latestBuild,
    latestVersion: latestVersion,
    updateUrl: updateUrl,
    announceAt: announceAt,
    softAt: softAt,
    deadlineAt: deadlineAt,
    serverNow: serverNow,
    maxPostpones: maxPostpones,
    softIntervalH: softIntervalH,
    bannerIntervalH: bannerIntervalH,
    readOnlyEnabled: readOnlyEnabled,
  );
}

/// Состояние политики на устройстве: кэш ответа сервера и отметки
/// «показали/отложили».
///
/// Все отметки времени — в СЕРВЕРНОМ времени (`server_now` из ответа плюс
/// прошедшее с ответа), чтобы подкрученные часы устройства не продлевали
/// «Позже» и не прятали экран.
class UpdatePolicyController {
  UpdatePolicyController(this._prefs, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final SharedPreferences _prefs;
  final DateTime Function() _clock;

  /// Глобальный слот, как у `VoiceRecordingGuard`: режим чтения нужен и
  /// экрану чата, и списку чатов, и обработчику шаринга.
  static final ValueNotifier<UpdatePolicy> current = ValueNotifier(
    UpdatePolicy.none,
  );

  static bool get readOnly => current.value.readOnly;

  /// Режим чтения для кода, который может бежать в ФОНОВОМ изоляте (пуши,
  /// ответ из шторки): там [current] пуст, источник — флаг в prefs. В фоне
  /// перечитываем prefs с диска — изолят мог жить дольше последней записи
  /// главного. В главном изоляте reload не зовём: он заменил бы кэш ещё не
  /// дописанных значений.
  static Future<bool> readOnlyAnywhere({required bool background}) async {
    if (readOnly) return true;
    if (!background) return false;
    // Сбой prefs не должен ломать показ пуша: кнопка ответа просто остаётся.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getBool(readOnlyKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static const cacheKey = 'update_policy.cache.v1';

  /// Флаг для фонового обработчика уведомлений (отдельный изолят не видит
  /// [current]): быстрый ответ из шторки в режиме чтения не отправляется.
  static const readOnlyKey = 'update_policy.read_only';
  static const _softShownKey = 'update_policy.soft_shown_at';
  static const _bannerDismissedKey = 'update_policy.banner_dismissed_at';

  /// Кэшированный «hard» старше этого без подтверждения сервера понижается:
  /// офлайн-кэш не должен запирать человека, до которого не доходит kill.
  static const staleHardAfter = Duration(hours: 72);

  UpdatePolicy _read() {
    final raw = _prefs.getString(cacheKey);
    if (raw == null) return UpdatePolicy.none;
    try {
      return UpdatePolicy.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return UpdatePolicy.none;
    }
  }

  int? get _fetchedAtLocalMs {
    final raw = _prefs.getString(cacheKey);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)['fetched_at_local_ms']
          as int?;
    } catch (_) {
      return null;
    }
  }

  Future<void> _publish(UpdatePolicy policy) async {
    current.value = policy;
    await _prefs.setBool(readOnlyKey, policy.readOnly);
  }

  /// Свежий ответ сервера для сборки [build].
  Future<void> applyFetched(UpdatePolicy policy, int build) async {
    await _prefs.setString(
      cacheKey,
      jsonEncode({
        ...policy.toJson(),
        'build': build,
        'fetched_at_local_ms': _clock().millisecondsSinceEpoch,
      }),
    );
    await _publish(policy);
  }

  /// Сервер недоступен: берём кэш ЭТОЙ сборки. Кэш другой сборки (человек
  /// обновился) недействителен; без кэша экраны не показываются.
  Future<void> applyUnavailable(int? build) async {
    var cached = _read();
    if (build == null || cached.build != build) {
      await _publish(UpdatePolicy.none);
      return;
    }
    final fetchedAt = _fetchedAtLocalMs;
    if (cached.stage == UpdateStage.hard &&
        (fetchedAt == null ||
            _clock().millisecondsSinceEpoch - fetchedAt >
                staleHardAfter.inMilliseconds)) {
      cached = cached.withStage(UpdateStage.soft);
    }
    await _publish(cached);
  }

  /// Оценка серверного «сейчас». Часы переведены назад — прошедшее считаем
  /// нулевым, а не отрицательным.
  DateTime serverNow() {
    final policy = current.value;
    final base = policy.serverNow;
    final fetchedAt = _fetchedAtLocalMs;
    if (base == null || fetchedAt == null) return _clock().toUtc();
    final elapsed = _clock().millisecondsSinceEpoch - fetchedAt;
    return base.add(Duration(milliseconds: elapsed < 0 ? 0 : elapsed));
  }

  String get _postponesKey =>
      'update_policy.postpones.${current.value.deadlineAt?.toIso8601String()}';

  /// Счётчик — на кампанию (дедлайн): новая кампания начинает с нуля.
  int get postponesUsed => _prefs.getInt(_postponesKey) ?? 0;

  int get postponesLeft {
    final left = current.value.maxPostpones - postponesUsed;
    return left < 0 ? 0 : left;
  }

  bool _intervalPassed(String key, int hours) {
    final raw = _prefs.getInt(key);
    if (raw == null) return true;
    final last = DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
    final now = serverNow();
    // Отметка «из будущего» (сдвиг часов/кэш) — интервал считаем прошедшим.
    if (now.isBefore(last)) return true;
    return now.difference(last) >= Duration(hours: hours);
  }

  /// Мягкий экран: этап soft, «Позже» ещё есть, прошло soft_interval_h.
  /// «Позже» исчерпано — экран больше не показываем (остаётся плашка в
  /// списке чатов): блокировка наступает только с дедлайна.
  bool get shouldShowSoft =>
      current.value.stage == UpdateStage.soft &&
      postponesLeft > 0 &&
      _intervalPassed(_softShownKey, current.value.softIntervalH);

  Future<void> markSoftShown() =>
      _prefs.setInt(_softShownKey, serverNow().millisecondsSinceEpoch);

  Future<void> postpone() => _prefs.setInt(_postponesKey, postponesUsed + 1);

  /// Баннер анонса закрываемый и возвращается через banner_interval_h;
  /// на прочих этапах плашку закрыть нельзя.
  bool get bannerVisible {
    final stage = current.value.stage;
    if (stage == UpdateStage.none) return false;
    if (stage != UpdateStage.announce) return true;
    return _intervalPassed(_bannerDismissedKey, current.value.bannerIntervalH);
  }

  Future<void> dismissBanner() =>
      _prefs.setInt(_bannerDismissedKey, serverNow().millisecondsSinceEpoch);
}
