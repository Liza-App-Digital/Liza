import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/hexagon_clipper.dart';
import 'package:liza/widgets/story_avatar_ring.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  // MxcImage без uri крутит backoff-таймеры — прокачиваем до конца теста.
  Future<void> drain(WidgetTester tester) async {
    for (final s in const [3, 5, 9, 17, 31]) {
      await tester.pump(Duration(seconds: s));
    }
  }

  testWidgets('none: кольца нет, child виден', (tester) async {
    await tester.pumpWidget(
      wrap(
        const StoryAvatarRing(state: StoryRingState.none, child: Text('AV')),
      ),
    );
    expect(find.text('AV'), findsOneWidget);
    final ring = tester.widget<StoryAvatarRing>(find.byType(StoryAvatarRing));
    expect(ring.state, StoryRingState.none);
  });

  testWidgets('unseen: рендерится без ошибок', (tester) async {
    await tester.pumpWidget(
      wrap(
        const StoryAvatarRing(state: StoryRingState.unseen, child: Text('AV')),
      ),
    );
    expect(find.text('AV'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('seen: рендерится без ошибок', (tester) async {
    await tester.pumpWidget(
      wrap(
        const StoryAvatarRing(state: StoryRingState.seen, child: Text('AV')),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  // ledger:RL-stories-rings-everywhere
  // AC:RL-stories-rings-everywhere/1
  for (final state in [StoryRingState.seen, StoryRingState.unseen]) {
    testWidgets('hexagonal ($state): кольцо и клип — сота, не круг', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          StoryAvatarRing(
            state: state,
            hexagonal: true,
            child: const Text('AV'),
          ),
        ),
      );
      expect(find.byType(ClipOval), findsNothing);
      expect(find.byType(ClipPath), findsOneWidget);
      final shapes = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(StoryAvatarRing),
              matching: find.byType(Container),
            ),
          )
          .map((c) => c.decoration)
          .whereType<ShapeDecoration>()
          .map((d) => d.shape)
          .toList();
      expect(shapes, hasLength(2));
      expect(shapes, everyElement(isA<HexagonBorder>()));
    });

    testWidgets('Avatar(isHexagonal, storyRing: $state): сотовое кольцо, '
        'бокс ровно size', (tester) async {
      await tester.pumpWidget(
        wrap(
          Avatar(name: 'Bot', isHexagonal: true, storyRing: state, size: 65),
        ),
      );
      final ring = tester.widget<StoryAvatarRing>(find.byType(StoryAvatarRing));
      expect(ring.hexagonal, isTrue);
      expect(tester.getSize(find.byType(StoryAvatarRing)), const Size(65, 65));
      expect(find.byType(ClipOval), findsNothing);
      await drain(tester);
    });
  }

  testWidgets('по умолчанию кольцо круглое (люди)', (tester) async {
    await tester.pumpWidget(
      wrap(Avatar(name: 'Ann', storyRing: StoryRingState.unseen, size: 65)),
    );
    expect(
      tester.widget<StoryAvatarRing>(find.byType(StoryAvatarRing)).hexagonal,
      isFalse,
    );
    expect(find.byType(ClipOval), findsOneWidget);
    await drain(tester);
  });
}
