// ledger:RL-macos-unified-banner-id

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/push_banner_id.dart';

void main() {
  test('pushBannerId совпадает с apns-collapse-id Sygnal (общий вектор) '
      'AC:RL-macos-unified-banner-id/1', () {
    // Тот же вектор закреплён в servers/sygnal/tests/test_apns.py
    // (test_collapse_id_matches_client_vector).
    expect(
      pushBannerId('Liza-1', r'$abc:liza.ru'),
      'oMxqDcgZXOmFx8QMvUrQcMLQcSVSyb_uwEHFR7y3Hqs',
    );
  });

  test('ID различает аккаунты и события, ≤ 64 байт без паддинга '
      'AC:RL-macos-unified-banner-id/2', () {
    final a = pushBannerId('Liza-1', r'$e1');
    expect(a, isNot(pushBannerId('Liza-2', r'$e1')));
    expect(a, isNot(pushBannerId('Liza-1', r'$e2')));
    expect(a.length, lessThanOrEqualTo(64));
    expect(a.contains('='), isFalse);
  });

  test(
    'по умолчанию нативный путь выключен (ждёт опыт Ф1.0) '
    'AC:RL-macos-unified-banner-id/3',
    () => expect(macosUnifiedBannerId, isFalse),
  );
}
