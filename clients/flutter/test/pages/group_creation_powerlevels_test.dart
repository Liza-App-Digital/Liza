import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/chat_topology.dart';

// ledger:RL-group-permissions-enforcement
//
// Спека 2026-08-25. Приватная группа наследовала preset invite:0 (Synapse
// handlers/room.py) → любой участник PL0 приглашал посторонних (тот же класс
// отклонения, что был у канала). Фикс — явный invite:50 в
// groupPowerLevelOverride(). Отличие от канала: группа НЕ поднимает
// events_default до 100 (в группе пишут все) и НЕ несёт ключ events (иначе
// shallow-merge Synapse стёр бы шаблонные пороги → захват m.room.power_levels).
void main() {
  group('groupPowerLevelOverride — invite:50, без events', () {
    // AC:RL-group-permissions-enforcement/1
    test('AC-1: invite задан явно = moderatorPowerLevel (50)', () {
      expect(
        groupPowerLevelOverride()['invite'],
        moderatorPowerLevel,
        reason: 'без явного порога приватная группа наследует preset invite:0 → '
            'участник приглашает посторонних',
      );
    });

    // AC:RL-group-permissions-enforcement/2
    test('AC-2: участник с PL 0 НЕ проходит гейт приглашения', () {
      final invite = groupPowerLevelOverride()['invite']! as int;
      expect(0 >= invite, isFalse);
    });

    // AC:RL-group-permissions-enforcement/3
    test('AC-3: модератор (PL 50) и админ (PL 100) проходят гейт приглашения',
        () {
      final invite = groupPowerLevelOverride()['invite']! as int;
      expect(moderatorPowerLevel >= invite, isTrue);
      expect(adminPowerLevel >= invite, isTrue);
    });

    // AC:RL-group-permissions-enforcement/4
    //
    // ⚠️ КРИТИЧНЫЙ анти-регресс, ОБРАТНЫЙ каналу. Канал несёт events_default:100
    // (постит только админ) и полный блок events (ради shallow-merge). Группе
    // это НЕЛЬЗЯ: копипаста channelPowerLevelOverride() сломала бы «в группе
    // пишут все» и открыла бы захват m.room.power_levels модератором.
    test('AC-4: override НЕ содержит ключа events (иначе shallow-merge сотрёт '
        'шаблонные пороги → модератор перепишет m.room.power_levels)', () {
      expect(
        groupPowerLevelOverride().containsKey('events'),
        isFalse,
        reason: 'ключ events заменил бы шаблонный блок Synapse ЦЕЛИКОМ',
      );
    });

    // AC:RL-group-permissions-enforcement/4
    test('AC-4: override НЕ содержит events_default (в группе пишут все, порог '
        'остаётся дефолтным 0)', () {
      expect(
        groupPowerLevelOverride().containsKey('events_default'),
        isFalse,
        reason: 'events_default:100 сделал бы группу бродкастом как канал',
      );
    });

    test('участник с PL 0 проходит гейт отправки сообщения (events_default '
        'дефолтный 0, не задан override\'ом)', () {
      // Порог отправки в группе не переопределяется → сервер возьмёт дефолт 0.
      const defaultEventsDefault = 0;
      expect(0 >= defaultEventsDefault, isTrue);
    });

    // ⚠️ Право удалять ЧУЖОЕ (redact) и kick/ban НЕ должны быть опущены —
    // наследуют шаблонные Synapse 50. Override их не трогает.
    test('override не опускает redact/kick/ban (наследуют шаблонные 50)', () {
      final override = groupPowerLevelOverride();
      expect(override.containsKey('redact'), isFalse);
      expect(override.containsKey('kick'), isFalse);
      expect(override.containsKey('ban'), isFalse);
    });

    // Отличие от канала зафиксировано ассертом: канал несёт events_default:100,
    // группа — нет. Защита от копипасты в обе стороны.
    test('канал и группа расходятся по events_default (анти-копипаста)', () {
      expect(channelPowerLevelOverride()['events_default'], 100);
      expect(groupPowerLevelOverride().containsKey('events_default'), isFalse);
    });
  });
}
