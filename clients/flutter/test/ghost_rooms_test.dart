// ledger:RL-ghost-room-local-prune
//
// Отбор комнат-призраков (заявка №55): удаление ЖИВОЙ комнаты хуже призрака,
// поэтому каждое условие — отдельный ассерт.
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/ghost_rooms.dart';

final _now = DateTime.utc(2026, 10, 20, 12);
final _old = _now.subtract(const Duration(days: 13));

GhostRoomSnapshot _room(String id, {bool space = false, DateTime? last}) =>
    GhostRoomSnapshot(id: id, isSpace: space, lastEventAt: last ?? _old);

List<String> _candidates(
  List<GhostRoomSnapshot> local, {
  Set<String>? server = const {},
  Set<String> seen = const {},
}) => ghostCandidates(
  localJoined: local,
  serverJoined: server,
  seenInSync: seen,
  now: _now,
);

void main() {
  // AC:RL-ghost-room-local-prune/1
  test('призрак: нет на сервере, не в sync, старый, не space → кандидат', () {
    expect(_candidates([_room('!ghost')]), ['!ghost']);
    final decision = decideGhostRemoval(
      probes: {'!ghost': GhostProbe.gone},
      localJoinedCount: 40,
    );
    expect(decision.remove, ['!ghost']);
    expect(decision.aborted, isFalse);
  });

  // AC:RL-ghost-room-local-prune/2
  group('живая комната не трогается', () {
    final cases = <String, List<String>>{
      'есть в /joined_rooms (DM)': _candidates([_room('!dm')], server: {'!dm'}),
      'есть в /joined_rooms (группа)': _candidates(
        [_room('!group')],
        server: {'!group'},
      ),
      'есть в /joined_rooms (федеративная компании)': _candidates(
        [_room('!c:nadezhda.liza.ru')],
        server: {'!c:nadezhda.liza.ru'},
      ),
      'space': _candidates([_room('!space', space: true)]),
      'пришла в sync за сессию': _candidates([_room('!x')], seen: {'!x'}),
      'событие моложе 10 мин': _candidates([
        _room('!fresh', last: _now.subtract(const Duration(minutes: 9))),
      ]),
      'нет lastEvent': _candidates([
        const GhostRoomSnapshot(
          id: '!empty',
          isSpace: false,
          lastEventAt: null,
        ),
      ]),
    };
    for (final entry in cases.entries) {
      test(entry.key, () => expect(entry.value, isEmpty));
    }

    test('пробник 200 → жива', () {
      expect(classifyGhostProbe(ok: true), GhostProbe.alive);
      final decision = decideGhostRemoval(
        probes: {'!lag': GhostProbe.alive},
        localJoinedCount: 40,
      );
      expect(decision.remove, isEmpty);
    });
  });

  // AC:RL-ghost-room-local-prune/3
  group('не можем судить → не удаляем', () {
    test('/joined_rooms не ответил', () {
      expect(_candidates([_room('!ghost')], server: null), isEmpty);
    });
    for (final errcode in [
      null,
      'M_LIMIT_EXCEEDED',
      'M_UNKNOWN_TOKEN',
      'M_UNKNOWN',
    ]) {
      test('пробник errcode=$errcode → unknown', () {
        expect(
          classifyGhostProbe(ok: false, errcode: errcode),
          GhostProbe.unknown,
        );
      });
    }
    test('unknown не попадает в удаление', () {
      final decision = decideGhostRemoval(
        probes: {'!a': GhostProbe.unknown},
        localJoinedCount: 40,
      );
      expect(decision.remove, isEmpty);
      expect(decision.aborted, isFalse);
    });
    for (final errcode in ['M_FORBIDDEN', 'M_NOT_FOUND']) {
      test('пробник errcode=$errcode → gone', () {
        expect(
          classifyGhostProbe(ok: false, errcode: errcode),
          GhostProbe.gone,
        );
      });
    }
  });

  // AC:RL-ghost-room-local-prune/4
  group('предохранитель от массового удаления', () {
    Map<String, GhostProbe> gone(int n) => {
      for (var i = 0; i < n; i++) '!g$i': GhostProbe.gone,
    };

    test('5 из 40 — удаляем', () {
      final d = decideGhostRemoval(probes: gone(5), localJoinedCount: 40);
      expect(d.remove, hasLength(5));
    });
    test('6 из 100 — больше 5, ничего', () {
      final d = decideGhostRemoval(probes: gone(6), localJoinedCount: 100);
      expect(d.remove, isEmpty);
      expect(d.aborted, isTrue);
    });
    test('3 из 10 — больше 20%, ничего', () {
      final d = decideGhostRemoval(probes: gone(3), localJoinedCount: 10);
      expect(d.remove, isEmpty);
      expect(d.aborted, isTrue);
    });
    test('1 из 3 — минимум одна комната допустима', () {
      final d = decideGhostRemoval(probes: gone(1), localJoinedCount: 3);
      expect(d.remove, hasLength(1));
    });
  });
}
