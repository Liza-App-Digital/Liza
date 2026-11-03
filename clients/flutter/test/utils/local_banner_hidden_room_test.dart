// ledger:RL-stories-invite-no-local-banner
import 'package:flutter_test/flutter_test.dart';
import 'package:liza/widgets/local_notifications_extension.dart';

void main() {
  // AC:RL-stories-invite-no-local-banner/1 — инвайт в скрытую (сторис) комнату
  // не даёт баннера, как для локального, так и для удалённого автора.
  test('инвайт в скрытую комнату — без баннера', () {
    for (final counts in [true, false]) {
      expect(
        skipsLocalBannerForHiddenRoom(
          isHiddenChat: true,
          countsTowardAppBadge: counts,
          isInvite: true,
        ),
        isTrue,
      );
    }
  });

  // AC:RL-stories-invite-no-local-banner/2 — обычный инвайт по-прежнему даёт баннер.
  test('обычный инвайт — баннер остаётся', () {
    for (final counts in [true, false]) {
      expect(
        skipsLocalBannerForHiddenRoom(
          isHiddenChat: false,
          countsTowardAppBadge: counts,
          isInvite: true,
        ),
        isFalse,
      );
    }
  });

  // AC:RL-stories-invite-no-local-banner/3 — прежнее поведение joined-комнат.
  test('joined: скрытая молчит, видимая непрочитанная звучит', () {
    expect(
      skipsLocalBannerForHiddenRoom(
        isHiddenChat: true,
        countsTowardAppBadge: false,
        isInvite: false,
      ),
      isTrue,
    );
    expect(
      skipsLocalBannerForHiddenRoom(
        isHiddenChat: false,
        countsTowardAppBadge: true,
        isInvite: false,
      ),
      isFalse,
    );
    expect(
      skipsLocalBannerForHiddenRoom(
        isHiddenChat: false,
        countsTowardAppBadge: false,
        isInvite: false,
      ),
      isTrue,
    );
  });
}
