import 'package:flutter_test/flutter_test.dart';
import 'package:liza/pages/chat_members/member_role_filter.dart';

void main() {
  group('matchesRoleFilter', () {
    test('all пропускает любой уровень', () {
      expect(matchesRoleFilter(0, MemberRoleFilter.all), isTrue);
      expect(matchesRoleFilter(50, MemberRoleFilter.all), isTrue);
      expect(matchesRoleFilter(100, MemberRoleFilter.all), isTrue);
    });

    // С 2026-10-14: владелец 100 и админ 99 — оба «админы» (RL-room-owner-transfer).
    test('admins — 99 и выше (админ и владелец)', () {
      expect(matchesRoleFilter(100, MemberRoleFilter.admins), isTrue);
      expect(matchesRoleFilter(99, MemberRoleFilter.admins), isTrue);
      expect(matchesRoleFilter(98, MemberRoleFilter.admins), isFalse);
      expect(matchesRoleFilter(101, MemberRoleFilter.admins), isTrue);
      expect(matchesRoleFilter(50, MemberRoleFilter.admins), isFalse);
      expect(matchesRoleFilter(0, MemberRoleFilter.admins), isFalse);
    });

    test('moderators — от 50 до 98', () {
      expect(matchesRoleFilter(50, MemberRoleFilter.moderators), isTrue);
      expect(matchesRoleFilter(98, MemberRoleFilter.moderators), isTrue);
      expect(matchesRoleFilter(99, MemberRoleFilter.moderators), isFalse);
      expect(matchesRoleFilter(100, MemberRoleFilter.moderators), isFalse);
      expect(matchesRoleFilter(49, MemberRoleFilter.moderators), isFalse);
    });

    test('users — ниже 50', () {
      expect(matchesRoleFilter(0, MemberRoleFilter.users), isTrue);
      expect(matchesRoleFilter(49, MemberRoleFilter.users), isTrue);
      expect(matchesRoleFilter(50, MemberRoleFilter.users), isFalse);
    });
  });
}
