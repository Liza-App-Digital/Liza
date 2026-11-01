// ledger:RL-bot-deep-links
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/bot_deep_link.dart';
import 'package:liza/utils/deep_link_target.dart';
import 'package:liza/utils/invite_link_parser.dart';
import 'package:liza/utils/pending_deep_link.dart';
import 'package:liza/utils/auth_proxy_service.dart';

void main() {
  // AC:RL-bot-deep-links/7
  test(
    'join_requested не ждёт joined sync и открывает ожидание заявки',
    () async {
      final target = await resolveInviteTargetFromResult(
        result: const InviteRedeemResult(
          status: 'join_requested',
          roomId: '!private:example.test',
        ),
        code: 'p_AbCdEfGh',
        awaitRoom: (room, {required expectSpace}) async =>
            throw StateError('Must not wait for join'),
        lookupRoomIsSpace: (_) => null,
      );
      expect(target, isA<DeepLinkJoinRequest>());
      expect(
        Uri.parse(deepLinkRoutePath(target)).queryParameters['room_id'],
        '!private:example.test',
      );
    },
  );
  // AC:RL-bot-deep-links/1
  test('web, AppLinks и custom scheme сохраняют start/startapp', () {
    for (final url in [
      'https://me.liza.ru/b/shop_bot?start=order_123',
      'liza://bot/shop_bot?start=order_123',
      'https://dev.me.liza.ru/b/shop_bot?start=order_123',
    ]) {
      final uri = Uri.parse(url);
      expect(parseBotLink(uri)?.route, '/b/shop_bot?start=order_123');
      expect(resolveInternalRoute(uri), '/b/shop_bot?start=order_123');
    }
    expect(
      webInitialLocation(
        Uri.parse('https://web.liza.ru/b/shop_bot?startapp=order_123'),
      ),
      '/b/shop_bot?startapp=order_123',
    );
    expect(
      parseWebBotLink(Uri.parse('/b/shop_bot?startapp'))?.opensApp,
      isTrue,
    );
  });

  // AC:RL-bot-deep-links/2
  test(
    'подмена host, повтор/конфликт параметров и невалидные значения отвергаются',
    () {
      for (final url in [
        'https://evil.test/b/shop_bot?start=a',
        'https://me.liza.ru/b/shop_bot?start=a&start=b',
        'https://me.liza.ru/b/shop_bot?start=a&startapp=b',
        'https://me.liza.ru/b/shop_bot?startgroup=a',
        'https://me.liza.ru/b/shop_bot?start=a%0Ab',
        'https://me.liza.ru/b/shop_bot?start=${'a' * 65}',
        'https://me.liza.ru/b/shop_bot?startapp=${'a' * 513}',
        'https://me.liza.ru/b/shop_bot/extra',
      ]) {
        expect(parseBotLink(Uri.parse(url)), isNull, reason: url);
      }
      expect(
        parseInviteCode(Uri.parse('https://liza.laba.pro/b/p_AbCdEfGh')),
        isNull,
      );
    },
  );

  // AC:RL-bot-deep-links/3
  test(
    'полная цель переживает web reload; initial дубликат подавляется',
    () async {
      SharedPreferences.setMockInitialValues({});
      PendingDeepLinkStore.debugResetInMemory();
      final link = parseWebBotLink(
        Uri.parse('/b/shop_bot?startapp=order_123'),
      )!;
      PendingDeepLinkStore.set(DeepLinkKind.bot, link.route);
      await Future<void>.delayed(Duration.zero);
      PendingDeepLinkStore.debugResetInMemory();
      final restored = await PendingDeepLinkStore.restore();
      expect(restored?.kind, DeepLinkKind.bot);
      expect(restored?.code, '/b/shop_bot?startapp=order_123');
      expect(
        await PendingDeepLinkStore.markDeepLinkHandled(link.route),
        isTrue,
      );
      expect(
        await PendingDeepLinkStore.markDeepLinkHandled(link.route),
        isFalse,
      );
      expect(
        await PendingDeepLinkStore.markDeepLinkHandled(
          '/b/shop_bot?startapp=order_456',
        ),
        isTrue,
      );
    },
  );
}
