import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/chat_topology.dart';

// Спек 2026-07-30 §1.8. Канал создаётся с events_default: 100 (постить может
// только админ). Без явного порога для m.reaction подписчик не мог поставить
// реакцию: её запрещал сам сервер, а клиентский гейт прятал ряд эмодзи.
void main() {
  test('канал создаётся с порогом m.reaction = 0', () {
    final override = channelPowerLevelOverride();
    expect(override['events_default'], 100,
        reason: 'постить в канал по-прежнему может только админ');
    final events = override['events'] as Map<String, Object?>;
    expect(events['m.reaction'], 0);
  });

  test('подписчик с PL 0 проходит гейт реакций при таком пороге', () {
    final override = channelPowerLevelOverride();
    final events = override['events'] as Map<String, Object?>;
    expect(
      canReactAt(
        ownPowerLevel: 0,
        reactionThreshold: events['m.reaction'] as int,
      ),
      isTrue,
    );
  });

  test('подписчик с PL 0 НЕ может постить', () {
    final override = channelPowerLevelOverride();
    expect(0 >= (override['events_default'] as int), isFalse);
  });

  // ledger:RL-channel-reaction-redaction-powerlevel
  //
  // Баг 2026-08-01: подписчик ставил реакцию, но снять не мог — сервер отдавал
  // M_FORBIDDEN. Снятие реакции это отправка m.room.redaction, а её порог в
  // events отсутствовал и наследовал events_default: 100.
  group('снятие своей реакции подписчиком', () {
    Map<String, Object?> events() =>
        channelPowerLevelOverride()['events']! as Map<String, Object?>;

    test('порог m.room.redaction открыт (0)', () {
      expect(
        events()['m.room.redaction'],
        0,
        reason: 'без явного порога он наследует events_default: 100 → '
            'подписчик не может снять СВОЮ реакцию (M_FORBIDDEN)',
      );
    });

    test('подписчик с PL 0 проходит гейт снятия своей реакции', () {
      expect(
        canRedactOwnAt(
          ownPowerLevel: 0,
          redactionThreshold: events()['m.room.redaction']! as int,
        ),
        isTrue,
      );
    });

    // ⚠️ ОПАСНАЯ РЕГРЕССИЯ. `redact` — право редактировать ЧУЖОЕ событие.
    // Опустив его до 0, мы дали бы любому подписканту удалять посты канала и
    // чужие реакции. Право снять СВОЁ даёт events['m.room.redaction'].
    test('top-level redact НЕ опущен до 0 — подписчик не трогает чужое', () {
      final override = channelPowerLevelOverride();
      final redact = override['redact'];
      expect(
        redact == null || (redact as int) >= moderatorPowerLevel,
        isTrue,
        reason: 'redact: 0 открыл бы удаление ЧУЖИХ постов канала подписчиком; '
            'право на своё событие даёт events[m.room.redaction]',
      );
    });

    test('модератор (PL 50) сохраняет право на чужие редакции по умолчанию', () {
      // Явного redact в override нет → действует шаблонный Synapse redact: 50.
      expect(channelPowerLevelOverride().containsKey('redact'), isFalse);
    });
  });

  // Регресс 2026-07-30. Synapse применяет powerLevelContentOverride через
  // shallow-merge (`power_level_content.update(...)`), поэтому ключ `events`
  // заменяется ЦЕЛИКОМ. Первая версия override'а несла только
  // `{'m.reaction': 0}` и тем самым стирала шаблонные пороги — они падали на
  // `state_default: 50`, и модератор канала (PL 50) мог переписать
  // `m.room.power_levels`, выдав себе админа.
  group('override не стирает шаблонные защитные пороги', () {
    Map<String, Object?> events() =>
        channelPowerLevelOverride()['events']! as Map<String, Object?>;

    test('m.room.power_levels недоступен модератору (PL 50)', () {
      expect(events()['m.room.power_levels'], isA<int>());
      expect(events()['m.room.power_levels'] as int, greaterThanOrEqualTo(100));
    });

    test('m.room.encryption недоступен модератору (PL 50)', () {
      expect(events()['m.room.encryption'], isA<int>());
      expect(events()['m.room.encryption'] as int, greaterThanOrEqualTo(100));
    });

    test('m.reaction остаётся открыт подписчику', () {
      expect(events()['m.reaction'], 0);
    });

    test('перечислены ВСЕ шаблонные пороги Synapse, не ниже шаблонных', () {
      final actual = events();
      for (final entry in synapseDefaultEventPowerLevels.entries) {
        expect(
          actual.containsKey(entry.key),
          isTrue,
          reason: '${entry.key} стёрт shallow-merge и упадёт на state_default 50',
        );
        expect(
          actual[entry.key] as int,
          greaterThanOrEqualTo(entry.value as int),
          reason: 'порог ${entry.key} занижен относительно шаблона Synapse',
        );
      }
    });

    test('модератор (PL 50) не проходит ни по одному защитному порогу', () {
      const moderatorPowerLevel = 50;
      const protectedEvents = [
        'm.room.power_levels',
        'm.room.history_visibility',
        'm.room.tombstone',
        'm.room.server_acl',
        'm.room.encryption',
      ];
      final actual = events();
      for (final type in protectedEvents) {
        expect(
          moderatorPowerLevel >= (actual[type]! as int),
          isFalse,
          reason: 'модератор канала не должен иметь права на $type',
        );
      }
    });

    // 150 сервер ставит только комнатам с msc4289_creator_power_enabled
    // (версии 12 / org.matrix.hydra.11). Инстансы Liza создают комнаты
    // дефолтной версии 10, где максимум PL создателя — 100: порог 150 там
    // недостижим ни для кого и ломает upgradeRoom (он шлёт tombstone).
    test('m.room.tombstone достижим админом канала (PL 100)', () {
      const adminPowerLevel = 100;
      expect(
        adminPowerLevel >= (events()['m.room.tombstone']! as int),
        isTrue,
        reason: 'порог tombstone выше 100 навсегда ломает апгрейд комнаты',
      );
    });
  });

  // ledger:RL-channel-permissions-enforcement
  //
  // Отклонение 2026-08-24 (проверено на локальном стеке не-админским аккаунтом):
  // preset `private_chat` Synapse выставляет `invite: 0` (handlers/room.py), а
  // override его не переопределял → в ПРИВАТНОМ канале любой подписчик (PL 0)
  // приглашал посторонних (сервер отдавал 200, membership=invite реально
  // создавался). Публичный канал (preset public_chat) уже получал 50 из шаблона
  // Synapse — расхождение. Фикс: явный invite: moderatorPowerLevel в override.
  group('приглашать в канал может только модератор (оба типа канала)', () {
    test('invite задан явно = moderatorPowerLevel (50)', () {
      expect(
        channelPowerLevelOverride()['invite'],
        moderatorPowerLevel,
        reason: 'без явного порога приватный канал наследует preset invite: 0 → '
            'подписчик приглашает посторонних',
      );
    });

    test('подписчик с PL 0 НЕ проходит гейт приглашения', () {
      final invite = channelPowerLevelOverride()['invite']! as int;
      expect(0 >= invite, isFalse);
    });

    test('модератор (PL 50) проходит гейт приглашения', () {
      final invite = channelPowerLevelOverride()['invite']! as int;
      expect(moderatorPowerLevel >= invite, isTrue);
    });
  });
}
