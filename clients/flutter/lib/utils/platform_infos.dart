import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/voice_recording_codec.dart';

abstract class PlatformInfos {
  static bool get isWeb => kIsWeb;
  static bool get isLinux => !kIsWeb && Platform.isLinux;
  static bool get isWindows => !kIsWeb && Platform.isWindows;
  static bool get isMacOS => !kIsWeb && Platform.isMacOS;
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isCupertinoStyle => isIOS || isMacOS;

  static bool get isMobile => isAndroid || isIOS;

  /// For desktops which don't support ChachedNetworkImage yet
  static bool get isBetaDesktop => isWindows || isLinux;

  static bool get isDesktop => isLinux || isWindows || isMacOS;

  static bool get usesTouchscreen => !isMobile;

  static bool get supportsVideoPlayer =>
      !PlatformInfos.isWindows && !PlatformInfos.isLinux;

  static bool get platformCanRecord => canRecordVoice(
    isWeb: isWeb,
    isMobile: isMobile,
    isMacOS: isMacOS,
    isWindows: isWindows,
  );

  static String get clientName =>
      '${AppSettings.applicationName.value} ${isWeb ? 'web' : Platform.operatingSystem}${kReleaseMode ? '' : 'Debug'}';

  static Future<String> getVersion() async {
    var version = kIsWeb ? 'Web' : 'Unknown';
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    return version;
  }

  /// Номер сборки (`+NNNN` из `pubspec.yaml`). На web берётся из
  /// `version.json`, который кладёт `flutter build web`; пустая строка значит,
  /// что номер недоступен — вызывающий код показывает тогда одну версию.
  static Future<String> getBuildNumber() async {
    try {
      return (await PackageInfo.fromPlatform()).buildNumber;
    } catch (_) {
      return '';
    }
  }

  static void showDialog(BuildContext context) async {
    final version = await PlatformInfos.getVersion();
    showAboutDialog(
      context: context,
      children: [
        Text(L10n.of(context).versionWithNumber(version)),
        Builder(
          builder: (innerContext) {
            return TextButton.icon(
              onPressed: () {
                context.go('/logs');
                Navigator.of(innerContext).pop();
              },
              icon: const Icon(Icons.list_outlined),
              label: Text(L10n.of(context).logs),
            );
          },
        ),
        Builder(
          builder: (innerContext) {
            return TextButton.icon(
              onPressed: () {
                context.go('/configs');
                Navigator.of(innerContext).pop();
              },
              icon: const Icon(Icons.settings_applications_outlined),
              label: Text(L10n.of(context).advancedConfigs),
            );
          },
        ),
      ],
      applicationIcon: Image.asset(
        'assets/logo.png',
        width: 64,
        height: 64,
        filterQuality: FilterQuality.medium,
      ),
      applicationName: AppSettings.applicationName.value,
    );
  }
}
