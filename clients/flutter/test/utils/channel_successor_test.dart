// ledger:RL-channel-sole-admin-leave
// AC:RL-channel-sole-admin-leave/1
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/chat_topology.dart';

void main() {
  group('isServiceAccountId', () {
    test('боты и поддержка — сервисные', () {
      for (final id in [
        '@liza:bots.liza.ru',
        '@gpt:bots.liza.ru',
        '@deepseek:bots.liza.ru',
        '@support:nadezhda.liza.ru',
      ]) {
        expect(isServiceAccountId(id), isTrue, reason: id);
      }
    });

    test('обычный пользователь — не сервисный', () {
      expect(isServiceAccountId('@nadezhda:nadezhda.liza.ru'), isFalse);
      expect(isServiceAccountId('@liza_fan:example.invalid'), isFalse);
    });
  });

  group('pickOwnerSuccessor — выбор преемника-админа', () {
    test('приоритет — модератор с максимальным PL', () {
      final id = pickOwnerSuccessor(const [
        OwnerSuccessorCandidate('@u1:x', 0),
        OwnerSuccessorCandidate('@mod50:x', 50),
        OwnerSuccessorCandidate('@mod70:x', 70),
      ]);
      expect(id, '@mod70:x');
    });

    test('нет модераторов → детерминированный первый по id', () {
      final id = pickOwnerSuccessor(const [
        OwnerSuccessorCandidate('@zoe:x', 0),
        OwnerSuccessorCandidate('@amy:x', 0),
      ]);
      expect(id, '@amy:x');
    });

    test('нет кандидатов → null (канал единственного участника удаляется)', () {
      expect(pickOwnerSuccessor(const []), isNull);
    });
  });
}
