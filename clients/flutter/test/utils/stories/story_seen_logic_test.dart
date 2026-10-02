import 'package:flutter_test/flutter_test.dart';
import 'package:liza/utils/stories/story_seen_logic.dart';

void main() {
  final ids = [r'$a', r'$b', r'$c'];
  bool none(String _) => false;

  test('indexOfEvent: найден / не найден / null', () {
    expect(indexOfEvent(ids, r'$b'), 1);
    expect(indexOfEvent(ids, r'$zzz'), -1);
    expect(indexOfEvent(ids, null), -1);
  });

  test('segmentSeen: покрыт receipt-позицией', () {
    expect(
      segmentSeen(index: 1, receiptIndex: 1, segmentId: r'$b', isLocallySeen: none),
      isTrue,
    );
    expect(
      segmentSeen(index: 2, receiptIndex: 1, segmentId: r'$c', isLocallySeen: none),
      isFalse,
    );
  });

  test('segmentSeen: локальная отметка перекрывает', () {
    expect(
      segmentSeen(
        index: 2,
        receiptIndex: -1,
        segmentId: r'$c',
        isLocallySeen: (id) => id == r'$c',
      ),
      isTrue,
    );
  });

  test('firstUnseenIndex: старт с первого непокрытого [ledger:RL-stories-first-unseen]', () {
    expect(
      firstUnseenIndex(segmentIds: ids, receiptIndex: 0, isLocallySeen: none),
      1,
    );
  });

  test('firstUnseenIndex: всё просмотрено - 0 [ledger:RL-stories-first-unseen]', () {
    expect(
      firstUnseenIndex(segmentIds: ids, receiptIndex: 2, isLocallySeen: none),
      0,
    );
  });

  test('firstUnseenIndex: ничего не просмотрено - 0', () {
    expect(
      firstUnseenIndex(segmentIds: ids, receiptIndex: -1, isLocallySeen: none),
      0,
    );
  });

  test('hasUnseenPositional', () {
    expect(
      hasUnseenPositional(segmentIds: ids, receiptIndex: 1, isLocallySeen: none),
      isTrue,
    );
    expect(
      hasUnseenPositional(segmentIds: ids, receiptIndex: 2, isLocallySeen: none),
      isFalse,
    );
    // receipt отстаёт, но хвост докрыт локальными отметками
    expect(
      hasUnseenPositional(
        segmentIds: ids,
        receiptIndex: 0,
        isLocallySeen: (id) => id == r'$b' || id == r'$c',
      ),
      isFalse,
    );
  });

  test('пустой список сегментов: firstUnseenIndex 0, hasUnseenPositional false [ledger:RL-stories-first-unseen]', () {
    expect(
      firstUnseenIndex(segmentIds: const [], receiptIndex: 0, isLocallySeen: none),
      0,
    );
    expect(
      hasUnseenPositional(segmentIds: const [], receiptIndex: 0, isLocallySeen: none),
      isFalse,
    );
  });

  test('hasUnseenPositional: receiptIndex за пределами длины списка - всё просмотрено', () {
    expect(
      hasUnseenPositional(segmentIds: ids, receiptIndex: 100, isLocallySeen: none),
      isFalse,
    );
  });

  group('viewsCountInTimeline [ledger:RL-stories-view-count]', () {
    // newest-first, как Timeline.events. $join — вход участника после s2,
    // $r1 — реакция зрителя @v на s1, отправленная уже после s2,
    // $old — событие до всех сегментов.
    const timeline = [r'$join', r'$r1', r'$s2', r'$s1', r'$s0', r'$old'];
    final positions = timelinePositions(timeline);
    const anchors = {r'$s0', r'$s1', r'$s2'};
    final reactions = {r'$r1': (sender: '@v:x', target: r'$s1')};
    bool none(String _) => false;

    List<int> counts(
      Map<String, String> receipts, {
      bool Function(String)? excluded,
      Map<String, int>? pos,
    }) => [
      for (final seg in const [r'$s0', r'$s1', r'$s2'])
        viewsCountInTimeline(
          positions: pos ?? positions,
          segmentId: seg,
          anchorIds: anchors,
          viewerReceipts: receipts,
          reactions: reactions,
          isExcluded: excluded ?? none,
        ),
    ];

    test(
      'AC:RL-stories-view-count/1 receipt на сегменте засчитывает его и все ранние',
      () {
        expect(counts({'@v:x': r'$s1'}), [1, 1, 0]);
        expect(counts({'@v:x': r'$s2'}), [1, 1, 1]);
        expect(counts({'@v:x': r'$s0'}), [1, 0, 0]);
      },
    );

    test(
      'AC:RL-stories-view-count/2 удалён последний сегмент, на котором receipt (QA 07.09)',
      () {
        // Удалённый сегмент остаётся в таймлайне redacted-событием и якорем;
        // счётчик показывают только оставшиеся s0/s1.
        expect(counts({'@v:x': r'$s2'}).sublist(0, 2), [1, 1]);
      },
    );

    test(
      'AC:RL-stories-view-count/3 удалён средний сегмент, на котором receipt',
      () {
        final c = counts({'@v:x': r'$s1'});
        expect([c[0], c[2]], [1, 0]);
      },
    );

    test(
      'AC:RL-stories-view-count/4 receipt на входе участника — не просмотр',
      () {
        expect(counts({'@v:x': r'$join'}), [0, 0, 0]);
      },
    );

    test(
      'AC:RL-stories-view-count/5 receipt на своей реакции засчитывает только её сегмент',
      () {
        expect(counts({'@v:x': r'$r1'}), [0, 1, 0]);
        // Чужая реакция под receipt зрителя якорем не становится.
        expect(counts({'@w:x': r'$r1'}), [0, 0, 0]);
      },
    );

    test(
      'AC:RL-stories-view-count/6 якоря нет в таймлайне или он старше — ноль',
      () {
        expect(counts({'@v:x': r'$unknown'}), [0, 0, 0]);
        expect(counts({'@v:x': r'$old'}), [0, 0, 0]);
      },
    );

    test(
      'AC:RL-stories-view-count/7 без таймлайна — точное совпадение по сегментам',
      () {
        final segmentsOnly = timelinePositions(const [r'$s2', r'$s1', r'$s0']);
        expect(counts({'@v:x': r'$s1'}, pos: segmentsOnly), [1, 1, 0]);
        expect(counts({'@v:x': r'$join'}, pos: segmentsOnly), [0, 0, 0]);
      },
    );

    test('AC:RL-stories-view-count/8 автор и AI-боты не считаются', () {
      final excluded = {'@author:x', '@ai:x'};
      expect(
        counts({
          '@author:x': r'$s2',
          '@ai:x': r'$s2',
          '@v:x': r'$s0',
        }, excluded: excluded.contains),
        [1, 0, 0],
      );
    });

    test(
      'AC:RL-stories-view-count/9 зрители на разных якорях считаются независимо',
      () {
        expect(
          counts({
            '@a:x': r'$s2',
            '@b:x': r'$s0',
            '@c:x': r'$s1',
            '@d:x': r'$join',
          }),
          [3, 2, 1],
        );
      },
    );

    test('сегмента нет в таймлайне — ноль', () {
      expect(
        viewsCountInTimeline(
          positions: positions,
          segmentId: r'$missing',
          anchorIds: anchors,
          viewerReceipts: const {'@v:x': r'$s2'},
          isExcluded: none,
        ),
        0,
      );
    });
  });
}
