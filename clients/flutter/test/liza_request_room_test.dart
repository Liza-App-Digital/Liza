import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/state_message.dart';
import 'package:liza/utils/liza_request_room.dart';

/// Минимальная комната: StateMessage в чате-запросе не должен дойти до
/// локализации события, поэтому нужны только id и маркер.
class _FakeRoom implements Room {
  _FakeRoom({required this.request}) {
    if (request) {
      states[lizaRequestStateType] = {
        '': StrippedStateEvent(
          type: lizaRequestStateType,
          content: const {'placeholder': 'Новый запрос'},
          senderId: '@u:hs',
        ),
      };
    }
  }

  final bool request;

  @override
  final String id = '!request:hs';

  @override
  final Map<String, Map<String, StrippedStateEvent>> states = {};

  @override
  StrippedStateEvent? getState(String typeKey, [String stateKey = '']) =>
      states[typeKey]?[stateKey];

  @override
  User unsafeGetUserFromMemoryOrFallback(String userId) => _FakeUser(userId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUser implements User {
  _FakeUser(this.id);

  @override
  final String id;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #calcDisplayname ||
        invocation.memberName == #displayName) {
      return 'Александр';
    }
    if (invocation.memberName == #id) return id;
    return super.noSuchMethod(invocation);
  }
}

Event _stateEvent(Room room) => Event(
      room: room,
      type: 'm.room.create',
      content: const {'creator': '@u:hs'},
      eventId: r'$create',
      senderId: '@u:hs',
      originServerTs: DateTime.fromMillisecondsSinceEpoch(0),
      stateKey: '',
    );

void main() {
  test('request room is recognised by its marker', () {
    expect(isLizaRequestRoom(_FakeRoom(request: true)), isTrue);
    expect(isLizaRequestRoom(_FakeRoom(request: false)), isFalse);
  });

  testWidgets('state events are hidden in a request room', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: StateMessage(_stateEvent(_FakeRoom(request: true))),
    ));

    expect(find.textContaining('создал'), findsNothing);
    expect(find.text('Больше событий'), findsNothing);
    expect(find.byType(SizedBox), findsWidgets);
  });

  testWidgets('ordinary room keeps its system events', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: StateMessage(_stateEvent(_FakeRoom(request: false))),
    ));

    await tester.pumpAndSettle();

    expect(find.textContaining('создал чат'), findsOneWidget);
  });
}
