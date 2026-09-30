import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'package:liza/utils/update_policy.dart';

/// Определяет платформу гостя веб-клиента по User-Agent.
///
/// Порядок проверок значим: iPad/iPhone содержат "Mac OS X" в UA, поэтому
/// Apple-мобильные обязаны проверяться ДО macOS, иначе владельцу iPhone
/// предложат установить macOS-сборку.
String? detectWebPlatformKey(String userAgent) {
  final ua = userAgent.toLowerCase();
  if (ua.contains('android')) return 'android';
  if (ua.contains('iphone') || ua.contains('ipad') || ua.contains('ipod')) {
    return 'ios';
  }
  if (ua.contains('mac os x') || ua.contains('macintosh')) return 'macos';
  if (ua.contains('windows')) return 'windows';
  return null;
}

class VersionGateResult {
  const VersionGateResult({
    required this.needsUpdate,
    this.updateUrl,
    this.latestVersion,
    this.installUrl,
  });

  final bool needsUpdate;
  final String? updateUrl;
  final String? latestVersion;

  /// Ссылка на установку нативного приложения — для веб-плашки. Заполняется
  /// и когда обновление не требуется: плашка установки не про версию.
  final String? installUrl;

  static const none = VersionGateResult(needsUpdate: false);
}

class VersionGateService {
  VersionGateService({
    required this.baseUrl,
    http.Client? httpClient,
    String? platformKeyOverride = _autoDetect,
    int? currentBuildOverride,
    String? webPlatformKey,
    String? packageNameOverride,
  })  : _http = httpClient ?? http.Client(),
        _platformKeyOverride = platformKeyOverride,
        _currentBuildOverride = currentBuildOverride,
        _webPlatformKey = webPlatformKey,
        _packageNameOverride = packageNameOverride;

  // Сентинел для параметра platformKeyOverride: отличает "не задан, определяй
  // платформу сам" (значение по умолчанию) от явного null = "платформа не
  // поддерживается, пропустить проверку" (используется в тестах).
  static const _autoDetect = '__auto__';

  final String baseUrl;
  final http.Client _http;
  final String? _platformKeyOverride;
  final int? _currentBuildOverride;

  /// Bundle id, заданный извне (тесты). null — спросить у [PackageInfo].
  final String? _packageNameOverride;

  /// Платформа гостя в вебе (см. [detectWebPlatformKey]). Передаётся снаружи,
  /// чтобы сервис не зависел от dart:html и оставался тестируемым.
  final String? _webPlatformKey;

  static const _timeout = Duration(seconds: 4);

  String? _resolvePlatformKey() {
    if (_platformKeyOverride != _autoDetect) return _platformKeyOverride;
    if (kIsWeb) return _webPlatformKey;
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    return null;
  }

  /// Bundle id запущенного приложения. На iOS/macOS строка version-gate
  /// адресуется именно им: там живут два приложения App Store (идёт миграция
  /// Apple-аккаунта) с независимой нумерацией сборок.
  ///
  /// Источник — фактический bundle id сборки, а НЕ dart-define `PUSH_APP_ID`:
  /// у того дефолт указывает на новый аккаунт, и сборка без флага (локальная,
  /// CI) выдала бы себя за новое приложение. Фактический bundle id соврать не
  /// может.
  ///
  /// На android/windows не нужен — там по одному приложению, строка лежит под
  /// именем платформы.
  Future<String?> _bundleId(String platform) async {
    if (!_bundleKeyedPlatforms.contains(platform)) return null;
    if (_packageNameOverride != null) return _packageNameOverride;
    if (kIsWeb) return null;
    try {
      return (await PackageInfo.fromPlatform()).packageName;
    } catch (_) {
      return null;
    }
  }

  static const _bundleKeyedPlatforms = {'ios', 'macos'};

  Future<int?> _currentBuild() async {
    if (_currentBuildOverride != null) return _currentBuildOverride;
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber);
  }

  Future<VersionGateResult> check() async {
    final platform = _resolvePlatformKey();
    if (platform == null) return VersionGateResult.none;
    try {
      // В вебе своей сборки нет: build не нужен, нас интересует только
      // install_url для плашки установки. На нативных платформах отсутствие
      // build по-прежнему означает «проверять нечего».
      final clientBuild = kIsWeb ? null : await _currentBuild();
      if (!kIsWeb && clientBuild == null) return VersionGateResult.none;
      final bundleId = await _bundleId(platform);
      final uri = Uri.parse('$baseUrl/version/$platform').replace(
        queryParameters: bundleId == null ? null : {'bundle': bundleId},
      );
      final resp = await _http.get(uri).timeout(_timeout);
      if (resp.statusCode != 200) return VersionGateResult.none;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final latestBuild = (data['build'] as num?)?.toInt();
      final installUrl = data['install_url'] as String?;
      if (latestBuild == null) {
        return VersionGateResult(needsUpdate: false, installUrl: installUrl);
      }
      if (clientBuild != null && clientBuild < latestBuild) {
        return VersionGateResult(
          needsUpdate: true,
          updateUrl: data['update_url'] as String?,
          latestVersion: data['version'] as String?,
          installUrl: installUrl,
        );
      }
      return VersionGateResult(needsUpdate: false, installUrl: installUrl);
    } catch (_) {
      return VersionGateResult.none;
    }
  }

  /// Этап обязательного обновления для этой сборки (`GET /policy`).
  ///
  /// `null` — проверять нечего (веб, неизвестная платформа, нет build).
  /// `policy == null` при известном build — сервер недоступен или ответ
  /// битый: вызывающий берёт кэш, а не сбрасывает этап.
  Future<({int build, UpdatePolicy? policy})?> fetchPolicy() async {
    if (kIsWeb) return null;
    final platform = _resolvePlatformKey();
    if (platform == null) return null;
    final int? build;
    try {
      build = await _currentBuild();
    } catch (_) {
      return null;
    }
    if (build == null) return null;
    try {
      final bundleId = await _bundleId(platform);
      final uri = Uri.parse('$baseUrl/policy/$platform').replace(
        queryParameters: {
          'build': '$build',
          if (bundleId != null) 'bundle': bundleId,
        },
      );
      final resp = await _http.get(uri).timeout(_timeout);
      // 404 — сервер явно не знает этот ключ: этапа нет, кэш не держим.
      // 5xx и сеть — временный сбой: вызывающий берёт кэш.
      if (resp.statusCode == 404) {
        return (build: build, policy: UpdatePolicy.none);
      }
      if (resp.statusCode != 200) return (build: build, policy: null);
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return (build: build, policy: UpdatePolicy.fromJson(data));
    } catch (_) {
      return (build: build, policy: null);
    }
  }

  /// Ссылка формы заявки на доступ (кнопка «Оставить заявку» на экране входа).
  /// null — кнопку не показываем.
  Future<String?> fetchRequestAccessUrl() async {
    try {
      final resp =
          await _http.get(Uri.parse('$baseUrl/onboarding')).timeout(_timeout);
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final url = data['request_access_url'] as String?;
      return (url == null || url.isEmpty) ? null : url;
    } catch (_) {
      return null;
    }
  }
}
