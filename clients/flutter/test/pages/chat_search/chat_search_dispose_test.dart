// GlitchTip #1845 (macOS 3772): поиск по файлам/медиа листает всю историю и
// идёт долго; экран закрывали раньше, чем `room.searchEvents` отвечал, и
// `ChatSearchController.startSearch` звал setState после dispose →
// «Null check operator» в State.setState (release) / FlutterError (debug).
//
// Страж монтирует РЕАЛЬНЫЙ ChatSearchPage; `searchEvents` комнаты держится
// Completer'ом, пока экран не снят. Red-proof: убрать `if (!mounted) return;`
// после await в ветке «Файлы» chat_search_page.dart → тест краснеет
// исключением setState() called after dispose().
//
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_search/chat_search_page.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

typedef _SearchResult = ({
  List<Event> events,
  String? nextBatch,
  DateTime? searchedUntil,
});

class _SlowSearchRoom extends Room {
  _SlowSearchRoom({required super.id, required super.client});

  final pending = Completer<_SearchResult>();

  @override
  Future<_SearchResult> searchEvents({
    String? searchTerm,
    bool Function(Event)? searchFunc,
    String? nextBatch,
    int limit = 1000,
    Set<String> includeEventTypes = const {
      EventTypes.Message,
      EventTypes.Encrypted,
    },
  }) => pending.future;
}

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
}

void main() {
  late Client client;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.dispose(closeDatabase: true);
  });

  testWidgets(
    'экран поиска закрыт до ответа поиска по файлам → без setState после dispose',
    (tester) async {
      final room = _SlowSearchRoom(
        id: '!search:example.invalid',
        client: client,
      );
      client.rooms.add(room);
      final showSearch = ValueNotifier(true);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Provider<liza_matrix.MatrixState>.value(
            value: _TestMatrixState(client),
            child: ValueListenableBuilder<bool>(
              valueListenable: showSearch,
              builder: (context, show, _) => show
                  ? ChatSearchPage(roomId: room.id)
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      // L10n грузится асинхронно — страница строится не в первом кадре.
      await tester.pumpAndSettle();

      final state = tester.state<ChatSearchController>(
        find.byType(ChatSearchPage),
      );
      // Вкладка «Файлы» — ветка из стека GlitchTip (chat_search_page.dart:97).
      state.tabController.index = 2;
      await tester.pump();
      expect(state.isLoading, isTrue, reason: 'поиск запущен и ждёт ответа');

      showSearch.value = false;
      await tester.pump();
      expect(state.mounted, isFalse);

      room.pending.complete((
        events: <Event>[],
        nextBatch: null,
        searchedUntil: null,
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
    },
  );
}
