// ledger:RL-seen-by-strip-avatar-resolution
// AC:RL-seen-by-strip-avatar-resolution/13
// AC:RL-seen-by-strip-avatar-resolution/14
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/avatar_stats.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/reader_profile_resolver.dart';

void main() {
  test('AC-13: title алёрта — маркер [media-, ≤99, без MXID', () {
    final t = Monitoring.avatarIssueTitle(
      'profile-error',
      'synapse.liza.laba.prodamus.tech',
    );
    expect(t, startsWith('[media-avatar-miss] reason=profile-error'));
    expect(t.length, lessThanOrEqualTo(Monitoring.maxAlertTitleLength));
    expect(t, isNot(contains('@')));
    expect(t, isNot(contains('mxc://')));
  });

  test('AC-13: отчёт под [health], без env= в title', () {
    final t = Monitoring.avatarReportTitle(3810);
    expect(t, startsWith(Monitoring.healthPrefix));
    expect(t, isNot(contains('env=')));
    expect(t.length, lessThanOrEqualTo(Monitoring.maxAlertTitleLength));
  });

  test('AC-13: троттл — не чаще раза в 30 мин на причину', () {
    final t0 = DateTime(2026, 11, 23, 12);
    expect(Monitoring.avatarIssueThrottleAllows('x-test', t0), isTrue);
    expect(
      Monitoring.avatarIssueThrottleAllows(
        'x-test',
        t0.add(const Duration(minutes: 29)),
      ),
      isFalse,
    );
    expect(
      Monitoring.avatarIssueThrottleAllows(
        'x-test',
        t0.add(const Duration(minutes: 31)),
      ),
      isTrue,
    );
  });

  test(
    'AC-13: всплеск error ≥5 при преобладании над resolved — один onBurst',
    () {
      final stats = AvatarStats();
      final fired = <String>[];
      stats.onBurst = fired.add;
      for (var i = 0; i < 4; i++) {
        stats.record(ReaderProfileOutcome.error);
      }
      expect(fired, isEmpty);
      stats.record(ReaderProfileOutcome.error);
      stats.record(ReaderProfileOutcome.error);
      expect(fired, ['profile-error']);
    },
  );

  test('AC-13: успехи перекрывают ошибки — всплеска нет; снимок обнуляет', () {
    final stats = AvatarStats();
    var fired = 0;
    stats.onBurst = (_) => fired++;
    for (var i = 0; i < 10; i++) {
      stats.record(ReaderProfileOutcome.resolved);
    }
    for (var i = 0; i < 6; i++) {
      stats.record(ReaderProfileOutcome.error);
    }
    expect(fired, 0);
    expect(stats.takeSnapshot(), {'resolved': 10, 'error': 6});
    expect(stats.isEmpty, isTrue);
  });

  test(
    'AC-14: маркер [media-avatar-miss] покрыт MEDIA_TITLE_MARKERS notifier',
    () {
      // Контракт без правки servers/**: читаем исходник notifier. Уберут `[media-`
      // из списка — алёрт уедет в общий ALERT_ROOM, тест покраснеет.
      final src = File(
        '../../servers/monitoring-notifier/notifier.py',
      ).readAsStringSync();
      final m = RegExp(
        r'MEDIA_TITLE_MARKERS\s*=\s*\(([^)]*)\)',
      ).firstMatch(src);
      expect(m, isNotNull);
      final markers = RegExp(
        r'"([^"]+)"',
      ).allMatches(m!.group(1)!).map((e) => e.group(1)!);
      final title = Monitoring.avatarIssueTitle(
        'profile-error',
        'synapse.liza',
      );
      expect(markers.any(title.startsWith), isTrue);
      // отчёт — health, не медиа-алёрт
      final report = Monitoring.avatarReportTitle(3811);
      expect(markers.any(report.startsWith), isFalse);
    },
  );
}
