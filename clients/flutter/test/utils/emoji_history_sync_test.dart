// ledger:RL-emoji-history-search
// Синк истории реакций через account data: реальный EmojiHistoryStore и
// реальный matrix Client на FakeMatrixApi; подменяется только HTTP-граница.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/emoji_history_store.dart';

import 'test_client.dart';

void main() {
  late FakeMatrixApi api;
  late Client client;
  late List<Map<String, Object?>> uploads;
  var failUpload = false;

  String uploadPath(Client c) =>
      '/client/v3/user/${Uri.encodeComponent(c.userID!)}/account_data/'
      '$emojiHistoryAccountDataType';

  Future<SharedPreferences> freshPrefs() async {
    SharedPreferences.setMockInitialValues({});
    return SharedPreferences.getInstance();
  }

  /// Состояние «другого устройства» приходит так же, как из /sync.
  void remote(Client c, List<List<Object>> entries, {int? sequence}) {
    c.accountData[emojiHistoryAccountDataType] = BasicEvent(
      type: emojiHistoryAccountDataType,
      content: {
        'version': 1,
        'reaction': {
          if (sequence != null) 'sequence': sequence,
          'entries': [
            for (final e in entries)
              {'emoji': e[0], 'count': e[1], 'last': e[2]},
          ],
        },
      },
    );
  }

  List<Object?> syncedEmojis(Client c) =>
      ((c.accountData[emojiHistoryAccountDataType]?.content['reaction']
                  as Map)['entries']
              as List)
          .map((e) => (e as Map)['emoji'])
          .toList();

  setUp(() async {
    uploads = [];
    failUpload = false;
    EmojiHistoryStore.syncDebounce = const Duration(milliseconds: 20);
    api = FakeMatrixApi();
    client = await prepareTestClient(loggedIn: true, httpClient: api);
    client.backgroundSync = false;
    api.api['PUT']![uploadPath(client)] = (body) {
      if (failUpload) throw Exception('сеть недоступна');
      uploads.add(jsonDecode(body as String) as Map<String, Object?>);
      return <String, Object?>{};
    };
  });

  tearDown(() async {
    // Отложенная запись теста не должна долететь в следующий тест.
    await EmojiHistoryStore.flushSync(client);
    EmojiHistoryStore.syncDebounce = const Duration(seconds: 3);
    await client.dispose(closeDatabase: true);
  });

  EmojiHistoryStore reactions(SharedPreferences prefs, {Client? c}) =>
      EmojiHistoryStore(
        prefs,
        client.userID!,
        EmojiUsage.reaction,
        client: c ?? client,
      );

  test(
    'AC:RL-emoji-history-search/8 слияние max/max не зависит от порядка и повторов',
    () async {
      const local = [
        ['🔥', 6, 4],
        ['🐈', 1, 2],
      ];
      const other = [
        ['🔥', 2, 9],
        ['🎯', 5, 7],
      ];
      // Устройство X: сначала своё, потом чужое; устройство Y — наоборот.
      final x = reactions(await freshPrefs());
      remote(client, local);
      x.ranked();
      remote(client, other);
      final xOrder = x.ranked();
      remote(client, other);
      x.ranked(); // повторное слияние того же — без изменений
      final y = reactions(await freshPrefs());
      remote(client, other);
      y.ranked();
      remote(client, local);
      final yOrder = y.ranked();
      remote(client, local);

      // 🔥: max(6, 2) = 6 > 🎯 5. «Побеждает последний пришедший» дал бы
      // разный порядок на X и Y — ровно то, на что жаловались.
      expect(xOrder, ['🔥', '🎯', '🐈']);
      expect(yOrder, xOrder);
      expect(x.ranked(), xOrder);
      expect(y.ranked(), xOrder);
    },
  );

  test(
    'AC:RL-emoji-history-search/10 новое использование старше любого удалённого',
    () async {
      final store = reactions(await freshPrefs());
      // На другом устройстве 🎯 выбран позже (больший last), частота равна.
      remote(client, [
        ['🎯', 1, 500],
      ], sequence: 500);
      expect(store.ranked(), ['🎯']);
      await store.record('🐈');
      // Часы Лэмпорта: 🐈 получает 501, а не локальный 1 — он новее.
      expect(store.ranked(), ['🐈', '🎯']);
    },
  );

  test(
    'AC:RL-emoji-history-search/11 серия записей = один PUT, без изменений = ни одного',
    () async {
      final store = reactions(await freshPrefs());
      for (final emoji in ['🔥', '🔥', '🐈']) {
        await store.record(emoji);
      }
      expect(uploads, isEmpty, reason: 'до debounce ничего не уходит');
      await EmojiHistoryStore.flushSync(client);
      expect(uploads, hasLength(1));
      expect(syncedEmojis(client), ['🔥', '🐈']);
      final reaction = uploads.single['reaction'] as Map;
      expect((reaction['entries'] as List).first, {
        'emoji': '🔥',
        'count': 2,
        'last': 2,
      });

      // Локальное эхо уже в accountData: повторная отправка без новых
      // реакций не нужна (защита от эхо-петли и 429).
      await store.record('🔥');
      remote(client, [
        ['🔥', 3, 4],
        ['🐈', 1, 3],
      ], sequence: 4);
      await EmojiHistoryStore.flushSync(client);
      expect(uploads, hasLength(1));
    },
  );

  test(
    'AC:RL-emoji-history-search/11 debounce отправляет сам по таймеру',
    () async {
      final store = reactions(await freshPrefs());
      await store.record('🎉');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await EmojiHistoryStore.flushSync(client);
      expect(uploads, hasLength(1));
      expect(syncedEmojis(client), ['🎉']);
    },
  );

  test(
    'AC:RL-emoji-history-search/11 ошибка PUT не откатывает историю, следующая запись уходит',
    () async {
      final store = reactions(await freshPrefs());
      failUpload = true;
      await store.record('🔥');
      await EmojiHistoryStore.flushSync(client);
      expect(uploads, isEmpty);
      expect(store.ranked(), ['🔥']);
      failUpload = false;
      await store.record('🐈');
      await EmojiHistoryStore.flushSync(client);
      expect(syncedEmojis(client), ['🔥', '🐈']);
    },
  );

  test(
    'AC:RL-emoji-history-search/11 повреждённый remote игнорируется',
    () async {
      final store = reactions(await freshPrefs());
      await store.record('🔥');
      for (final broken in <Object?>[
        'broken',
        42,
        [],
        {'entries': 'x'},
        {
          'entries': [
            null,
            {'emoji': '', 'count': 1, 'last': 1},
            {'emoji': '🐈', 'count': -1, 'last': 3},
          ],
        },
      ]) {
        client.accountData[emojiHistoryAccountDataType] = BasicEvent(
          type: emojiHistoryAccountDataType,
          content: {'reaction': broken},
        );
        expect(store.ranked(), ['🔥']);
      }
    },
  );

  test(
    'AC:RL-emoji-history-search/11 без client — ни таймера, ни запроса',
    () async {
      final store = EmojiHistoryStore(
        await freshPrefs(),
        client.userID!,
        EmojiUsage.reaction,
      );
      await store.record('🔥');
      await EmojiHistoryStore.flushSync(client);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(uploads, isEmpty);
      expect(store.ranked(), ['🔥']);
    },
  );

  test(
    'AC:RL-emoji-history-search/14 текст не синкается; чужой аккаунт не читает и не пишет',
    () async {
      final prefs = await freshPrefs();
      final text = EmojiHistoryStore(
        prefs,
        client.userID!,
        EmojiUsage.text,
        client: client,
      );
      remote(client, [
        ['🎯', 9, 9],
      ]);
      expect(text.ranked(), isEmpty, reason: 'remote только для реакций');
      await text.record('🇷🇺');
      await EmojiHistoryStore.flushSync(client);
      expect(uploads, isEmpty);

      // Store чужого MXID с этим client (устаревшее событие после смены
      // аккаунта) не сливает и не отправляет историю этого client.
      final foreign = EmojiHistoryStore(
        prefs,
        '@someone:else.invalid',
        EmojiUsage.reaction,
        client: client,
      );
      expect(foreign.ranked(), isEmpty);
      await foreign.record('🐈');
      await EmojiHistoryStore.flushSync(client);
      expect(uploads, isEmpty);
    },
  );

  test(
    'AC:RL-emoji-history-search/11 выход из аккаунта во время debounce — без PUT',
    () async {
      final store = reactions(await freshPrefs());
      await store.record('🔥');
      await client.logout();
      await EmojiHistoryStore.flushSync(client);
      expect(uploads, isEmpty);
    },
  );
}
