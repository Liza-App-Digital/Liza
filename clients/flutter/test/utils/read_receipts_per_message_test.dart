// Тесты getReadReceiptsPerMessage — МОДЕЛЬ-ГРАНИЦА (задача 2026-06-23): ПО ОДНОЙ
// аватарке на участника под его ПОСЛЕДНИМ прочитанным сообщением. Включаем
// всех: других участников (п.1), автора под его же сообщением (п.2) и себя —
// своё новейшее сообщение прочитано мной сразу (п.2.1).
//
// Граница участника = max(позиция квитанции m.read, его новейшее собственное
// сообщение). Сервер не шлёт m.read автору на его же событие, поэтому «своё
// новейшее» поднимаем вручную.
//
// Рендер — под конкретным событием-границей (message.dart, виджет-уровень,
// здесь не тестируется).
//
// Страж РЕГРЕССИИ (ledger:RL-receipts-indicators): аватарки читателей не
// исчезают массово (как было в сборке 3662).

// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
// TimelineChunk не реэкспортируется из matrix.dart — берём из src напрямую.
import 'package:matrix/src/models/timeline_chunk.dart';

import 'package:liza/utils/gallery_read_receipts.dart';
import 'package:liza/utils/room_status_extension.dart';

import 'test_client.dart';

const _nadya = '@nadya:example.invalid';
const _roman = '@roman:example.invalid';

void main() {
  late Client client;
  late String myId; // реальный client.userID фейкового API

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    myId = client.userID!;
  });

  tearDown(() async {
    // Статика оптимистичных квитанций живёт весь процесс — чистим, иначе
    // высокая позиция из одного теста утечёт в другой (тот же roomId).
    RoomStatusExtension.resetOptimisticOwnReads();
    // unsafeGetUserFromMemoryOrFallback запускает фоновый requestUser (DB).
    // Даём ему осесть до закрытия БД, иначе fire-and-forget падает
    // database_closed уже после теста и помечает его как [E].
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.dispose(closeDatabase: true);
  });

  Room buildRoom({
    Map<String, dynamic> receiptOthers = const {},
    Map<String, dynamic>? myReceipt, // моя квитанция m.read: {'e': id, 'ts': N}
  }) {
    return Room(
      id: '!room:example.invalid',
      client: client,
      roomAccountData: {
        LatestReceiptState.eventType: BasicEvent(
          type: LatestReceiptState.eventType,
          content: {
            'global': {
              'others': receiptOthers,
              if (myReceipt != null) 'latest': myReceipt,
            },
          },
        ),
      },
    );
  }

  // events идут новейшие→старейшие (как timeline.events в SDK).
  Event msg(Room room, String id, String sender, int ts) => Event(
    eventId: id,
    senderId: sender,
    originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
    type: EventTypes.Message,
    content: {'msgtype': 'm.text', 'body': id},
    room: room,
  );

  // Правка (m.replace) сообщения [origId]. SDK держит её ОТДЕЛЬНЫМ событием в
  // timeline.events (свой eventId, поздний ts), type == m.room.message —
  // relationshipType вычисляется из content['m.relates_to']['rel_type'].
  Event edit(Room room, String id, String origId, String sender, int ts) =>
      Event(
        eventId: id,
        senderId: sender,
        originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
        type: EventTypes.Message,
        content: {
          'msgtype': 'm.text',
          'body': '* edited',
          'm.new_content': {'msgtype': 'm.text', 'body': 'edited'},
          'm.relates_to': {'rel_type': 'm.replace', 'event_id': origId},
        },
        room: room,
      );

  // Член медиа-альбома: m.image с полем com.liza.gallery {id, i, n}. Для
  // getReadReceiptsPerMessage поведение как у обычного сообщения (оно про
  // галерею не знает) — не-anchor члены (i>0) скрывает уже ЛЕНТА
  // (gallerySkipEventIds), поэтому граница ошибочно садится на новейший
  // скрытый член, а ремап (mergeGalleryReadReceipts) возвращает её на anchor.
  Event galleryImg(
    Room room,
    String id,
    String sender,
    int ts, {
    required String gid,
    required int i,
    required int n,
  }) => Event(
    eventId: id,
    senderId: sender,
    originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
    type: EventTypes.Message,
    content: {
      'msgtype': 'm.image',
      'body': id,
      'url': 'mxc://example.invalid/$id',
      'com.liza.gallery': {'id': gid, 'i': i, 'n': n},
    },
    room: room,
  );

  Timeline timelineOf(Room room, List<Event> events) => Timeline(
    room: room,
    chunk: TimelineChunk(events: events),
  );

  Set<String> readersOf(
    Map<String, List<MessageReadReceipt>> result,
    String eventId,
  ) => (result[eventId] ?? const []).map((r) => r.user.id).toSet();

  bool hasAvatarOf(
    Map<String, List<MessageReadReceipt>> result,
    String userId,
  ) => result.values.any((list) => list.any((r) => r.user.id == userId));

  // Сколько раз всего встречается аватарка участника (граница = ровно одно
  // событие, поэтому ожидаем 1).
  int avatarCountOf(
    Map<String, List<MessageReadReceipt>> result,
    String userId,
  ) => result.values
      .expand((list) => list)
      .where((r) => r.user.id == userId)
      .length;

  test(
    'РЕГРЕССИЯ: активная группа — аватарки читателей ПРИСУТСТВУЮТ (не исчезают '
    'массово) [ledger:RL-receipts-indicators]',
    () {
      final room = buildRoom(
        receiptOthers: {
          _nadya: {'e': 'my_new', 'ts': 510},
          _roman: {'e': 'my_new', 'ts': 520},
        },
      );
      final events = [
        msg(room, 'my_new', myId, 500),
        msg(room, 'roman_own', _roman, 400),
        msg(room, 'nadya_own', _nadya, 300),
        msg(room, 'my_old', myId, 100),
      ];
      final result = room.getReadReceiptsPerMessage(timelineOf(room, events));

      expect(hasAvatarOf(result, _nadya), isTrue, reason: 'Надя не исчезает');
      expect(hasAvatarOf(result, _roman), isTrue, reason: 'Роман не исчезает');
      // И я под своим новейшим (п.2.1).
      expect(hasAvatarOf(result, myId), isTrue, reason: 'моя аватарка есть');
    },
  );

  test('граница: аватарка участника стоит РОВНО ОДИН раз — под его последним '
      'прочитанным сообщением, не кумулятивно (п.1)', () {
    final room = buildRoom(
      receiptOthers: {
        _roman: {'e': 'my_c', 'ts': 320}, // дочитал до новейшего my_c (300)
        _nadya: {'e': 'roman_b', 'ts': 220}, // дочитал только до roman_b (200)
      },
    );
    final events = [
      msg(room, 'my_c', myId, 300), // моё новейшее
      msg(room, 'roman_b', _roman, 200),
      msg(room, 'my_a', myId, 100), // моё старое
    ];
    final result = room.getReadReceiptsPerMessage(timelineOf(room, events));

    // Роман — только под my_c (его граница), не под roman_b/my_a.
    expect(avatarCountOf(result, _roman), 1, reason: 'Роман — одна аватарка');
    expect(readersOf(result, 'my_c').contains(_roman), isTrue);
    // Надя — только под roman_b (её граница), НЕ кумулятивно под my_a.
    expect(avatarCountOf(result, _nadya), 1, reason: 'Надя — одна аватарка');
    expect(readersOf(result, 'roman_b').contains(_nadya), isTrue);
    expect(
      readersOf(result, 'my_a').contains(_nadya),
      isFalse,
      reason: 'не кумулятив: под старым сообщением аватарки нет',
    );
    // Я — под своим новейшим my_c (п.2.1).
    expect(readersOf(result, 'my_c').contains(myId), isTrue);
  });

  test('автор показывается ПОД СВОИМ сообщением, и я — под своим, даже без '
      'единой квитанции m.read (п.2, п.2.1)', () {
    final room = buildRoom(); // никаких квитанций вообще
    final events = [
      msg(room, 'my_c', myId, 300),
      msg(room, 'roman_b', _roman, 200),
      msg(room, 'my_a', myId, 100),
    ];
    final result = room.getReadReceiptsPerMessage(timelineOf(room, events));

    // Роман — под своим единственным сообщением (п.2).
    expect(
      readersOf(result, 'roman_b').contains(_roman),
      isTrue,
      reason: 'автор под своим сообщением',
    );
    // Я — под СВОИМ новейшим my_c (а не под my_a) (п.2.1).
    expect(readersOf(result, 'my_c').contains(myId), isTrue);
    expect(readersOf(result, 'my_a').contains(myId), isFalse);
  });

  test('без своей квитанции моя аватарка стоит под МОИМ новейшим сообщением '
      '(fallback, п.2.1)', () {
    final room = buildRoom(
      receiptOthers: {
        _roman: {'e': 'roman_b', 'ts': 210},
      },
    );
    final events = [
      msg(room, 'roman_b', _roman, 200), // чужое новейшее
      msg(room, 'my_a', myId, 100), // моё (старее чужого)
    ];
    final result = room.getReadReceiptsPerMessage(timelineOf(room, events));

    expect(
      readersOf(result, 'my_a').contains(myId),
      isTrue,
      reason: 'без своей квитанции — под своим сообщением',
    );
    expect(avatarCountOf(result, myId), 1);
  });

  test(
    'БАГ ПРОДА: оптимистичный read marker двигает мою аватарку к прочитанному, '
    'когда сервер ещё НЕ прислал latestOwnReceipt (эхо запаздывает/нет) '
    '[ledger:RL-receipts-indicators]',
    () {
      // global.latest НЕ задан — как в проде ДО серверного эха своей квитанции.
      // Именно поэтому юнит-тест БАГ1 (ниже) был зелёным, а прод — нет: там
      // свою квитанцию впрыскивают, в проде её в receiptState ещё нет.
      final room = buildRoom(
        receiptOthers: {
          _roman: {'e': 'roman_new', 'ts': 410},
        },
      );
      final events = [
        msg(room, 'roman_new', _roman, 400), // чужое новейшее — я его прочитал
        msg(room, 'my_photo', myId, 300), // моё последнее СВОЁ (фото)
        msg(room, 'roman_old', _roman, 200),
      ];

      // Без оптимистики моя аватарка залипает на my_photo (шаг 2) — ровно баг.
      final before = room.getReadReceiptsPerMessage(timelineOf(room, events));
      expect(
        readersOf(before, 'my_photo').contains(myId),
        isTrue,
        reason: 'до оптимистики — под своим фото (воспроизводим баг)',
      );

      // Клиент отметил прочитанным roman_new (chat.setReadMarker → record).
      room.recordOwnReadMarkerTs(400);
      final after = room.getReadReceiptsPerMessage(timelineOf(room, events));
      expect(
        readersOf(after, 'roman_new').contains(myId),
        isTrue,
        reason: 'после оптимистики — под последним прочитанным roman_new',
      );
      expect(
        readersOf(after, 'my_photo').contains(myId),
        isFalse,
        reason: 'аватарка ушла с фото',
      );
      expect(avatarCountOf(after, myId), 1, reason: 'ровно одна аватарка');
    },
  );

  test(
    'БАГ1: моя квитанция m.read двигает мою аватарку к ПОСЛЕДНЕМУ прочитанному '
    'мной (чужому) сообщению, а не к моему последнему',
    () {
      final room = buildRoom(
        // Я прочитал сообщение Даниэля (новейшее), своя квитанция стоит на нём.
        myReceipt: {'e': 'daniel_new', 'ts': 260},
      );
      final events = [
        msg(room, 'daniel_new', _roman, 200), // чужое новейшее (Даниэль)
        msg(room, 'my_old', myId, 100), // моё (предпоследнее)
      ];
      final result = room.getReadReceiptsPerMessage(timelineOf(room, events));

      expect(
        readersOf(result, 'daniel_new').contains(myId),
        isTrue,
        reason: 'моя аватарка под последним прочитанным (сообщение Даниэля)',
      );
      expect(
        readersOf(result, 'my_old').contains(myId),
        isFalse,
        reason: 'НЕ залипает на моём предпоследнем сообщении',
      );
      expect(avatarCountOf(result, myId), 1);
    },
  );

  test('БАГ2: в кластере под чужим сообщением его АВТОР — первым (прочитал в '
      'момент отправки), остальные дочитавшие — после', () {
    final room = buildRoom(
      receiptOthers: {
        _nadya: {'e': 'daniel_new', 'ts': 250}, // Надя дочитала позже
      },
      myReceipt: {'e': 'daniel_new', 'ts': 260}, // я дочитал ещё позже
    );
    final events = [
      msg(room, 'daniel_new', _roman, 200), // автор — _roman (Даниэль)
      msg(room, 'my_old', myId, 100),
    ];
    final result = room.getReadReceiptsPerMessage(timelineOf(room, events));

    final cluster = result['daniel_new'] ?? const [];
    expect(
      cluster.first.user.id,
      _roman,
      reason: 'автор сообщения стоит первым в кластере',
    );
    expect(
      cluster.map((r) => r.user.id),
      containsAll(<String>[_roman, _nadya, myId]),
      reason: 'в кластере автор + двое дочитавших',
    );
  });

  test(
    'РЕДАКТИРОВАНИЕ: автор правит прочитанное сообщение — аватарки других НЕ '
    'пропадают, остаются под ОРИГИНАЛОМ (правка не меняет статус прочтения) '
    '[ledger:RL-receipts-indicators]',
    () {
      // Я отправил orig (ts300), Надя его прочитала (квитанция на orig).
      // Затем я РЕДАКТИРУЮ orig → отдельное m.replace-событие с поздним ts500.
      final room = buildRoom(
        receiptOthers: {
          _nadya: {'e': 'orig', 'ts': 300},
        },
      );
      final events = [
        edit(room, 'edit1', 'orig', myId, 500), // правка — новейшее событие
        msg(room, 'orig', myId, 300), // оригинал (видимый)
      ];
      final result = room.getReadReceiptsPerMessage(timelineOf(room, events));

      // Аватарка Нади осталась под видимым оригиналом, не уехала на скрытый
      // eventId правки.
      expect(
        readersOf(result, 'orig').contains(_nadya),
        isTrue,
        reason: 'Надя осталась под оригиналом после правки',
      );
      expect(
        readersOf(result, 'edit1').contains(_nadya),
        isFalse,
        reason: 'аватарка не уехала на нерендерящееся edit-событие',
      );
      // И я (автор) — тоже под оригиналом, а не под правкой.
      expect(readersOf(result, 'orig').contains(myId), isTrue);
      expect(readersOf(result, 'edit1').contains(myId), isFalse);
      expect(avatarCountOf(result, _nadya), 1);
      expect(avatarCountOf(result, myId), 1);
    },
  );

  test(
    'РЕДАКТИРОВАНИЕ: читатель ПЕРЕОТМЕТИЛ прочтение на edit-событии — аватарка '
    'всё равно садится на видимый оригинал; done_all консистентен с аватаркой '
    '[ledger:RL-receipts-indicators]',
    () {
      // Квитанция Нади указывает прямо на edit-событие (она была активна и
      // переотметила прочтение на свежей правке).
      final room = buildRoom(
        receiptOthers: {
          _nadya: {'e': 'edit1', 'ts': 500},
        },
      );
      final events = [
        edit(room, 'edit1', 'orig', myId, 500),
        msg(room, 'orig', myId, 300),
      ];
      final timeline = timelineOf(room, events);
      final result = room.getReadReceiptsPerMessage(timeline);

      expect(
        readersOf(result, 'orig').contains(_nadya),
        isTrue,
        reason: 'квитанция на правке → аватарка на видимом оригинале',
      );
      expect(readersOf(result, 'edit1').contains(_nadya), isFalse);

      // Кросс-проверка единого критерия (исторический баг «аватарка есть,
      // галочки нет»): readUpToTs пересекает оригинал → done_all на нём стоит,
      // синхронно с аватаркой.
      expect(
        room.readUpToTs(timeline) >= 300,
        isTrue,
        reason: 'done_all на оригинале консистентен с его аватаркой',
      );
    },
  );

  test('РЕДАКТИРОВАНИЕ: несколько правок подряд — никто не уезжает на edit-id, '
      'аватарки по одной под оригиналом [ledger:RL-receipts-indicators]', () {
    final room = buildRoom(
      receiptOthers: {
        _nadya: {'e': 'orig', 'ts': 300},
      },
    );
    final events = [
      edit(room, 'edit2', 'orig', myId, 600), // вторая правка — новейшая
      edit(room, 'edit1', 'orig', myId, 500),
      msg(room, 'orig', myId, 300),
    ];
    final result = room.getReadReceiptsPerMessage(timelineOf(room, events));

    expect(readersOf(result, 'orig').contains(_nadya), isTrue);
    expect(readersOf(result, 'orig').contains(myId), isTrue);
    expect(result.containsKey('edit1'), isFalse);
    expect(result.containsKey('edit2'), isFalse);
    expect(avatarCountOf(result, _nadya), 1);
    expect(avatarCountOf(result, myId), 1);
  });

  test('РЕДАКТИРОВАНИЕ не последнего сообщения: правка orig не раздувает границу '
      'автора — он остаётся под своим видимым сообщением, читатель под своим '
      '[ledger:RL-receipts-indicators]', () {
    // orig (моё, ts300, прочитано Надей) → m2 (Романа, ts600, видимое,
    // прочитано Надей) → правка orig с поздним ts700 (новейшее событие).
    final room = buildRoom(
      receiptOthers: {
        _nadya: {'e': 'm2', 'ts': 650},
      },
    );
    final events = [
      edit(room, 'edit1', 'orig', myId, 700), // новейшее, но скрытое
      msg(room, 'm2', _roman, 600), // видимое новейшее реальное
      msg(room, 'orig', myId, 300),
    ];
    final result = room.getReadReceiptsPerMessage(timelineOf(room, events));

    // Моя граница (автор orig) НЕ задирается правкой до ts700 — я под orig.
    expect(
      readersOf(result, 'orig').contains(myId),
      isTrue,
      reason: 'правка своего старого сообщения не уводит мою аватарку вперёд',
    );
    expect(result.containsKey('edit1'), isFalse);
    // Надя дочитала до m2 → её аватарка под m2 (и автор m2 — Роман — тоже там).
    expect(readersOf(result, 'm2').contains(_nadya), isTrue);
    expect(readersOf(result, 'm2').contains(_roman), isTrue);
  });

  test(
    'РЕДАКТИРОВАНИЕ своего сообщения: чужой done_all на нём НЕ пропадает после '
    'моей правки [ledger:RL-receipts-indicators]',
    () {
      // Моё orig (ts300) прочитала Надя; я его правлю (edit1, ts500).
      final room = buildRoom(
        receiptOthers: {
          _nadya: {'e': 'orig', 'ts': 300},
        },
      );
      final events = [
        edit(room, 'edit1', 'orig', myId, 500),
        msg(room, 'orig', myId, 300),
      ];
      final timeline = timelineOf(room, events);

      // done_all своего оригинала: readUpToTs (по чужим квитанциям) >= ts orig.
      expect(
        room.readUpToTs(timeline) >= 300,
        isTrue,
        reason: 'правка своего сообщения не ломает чужой done_all на оригинале',
      );
      // И аватарка Нади на оригинале — синхронно с галочкой.
      final result = room.getReadReceiptsPerMessage(timeline);
      expect(readersOf(result, 'orig').contains(_nadya), isTrue);
    },
  );

  test('ГАЛЕРЕЯ: своя аватарка уезжает на скрытый новейший член альбома, ремап '
      'возвращает её на видимый anchor [ledger:RL-receipts-indicators]', () {
    // Александр отправил 2 скрина одним альбомом. Лента рисует только anchor
    // (i=0, самый ранний ts), новейший член (i=1) скрыт. Без ремапа моя
    // граница садится на скрытый $g1 → аватарке негде отрисоваться (баг
    // «моргнула и скрылась»).
    final room = buildRoom();
    final events = [
      galleryImg(room, r'$g1', myId, 300, gid: 'alb', i: 1, n: 2), // скрытый
      galleryImg(room, r'$g0', myId, 200, gid: 'alb', i: 0, n: 2), // anchor
      msg(room, r'$older', _roman, 100),
    ];
    final timeline = timelineOf(room, events);

    // Воспроизводим баг: сырая граница на скрытом новейшем члене.
    final raw = room.getReadReceiptsPerMessage(timeline);
    expect(
      readersOf(raw, r'$g1').contains(myId),
      isTrue,
      reason: 'до ремапа граница на скрытом новейшем члене галереи (баг)',
    );
    expect(readersOf(raw, r'$g0').contains(myId), isFalse);

    // Ремап скрытого члена $g1 на anchor $g0 (как строит chat_event_list).
    final fixed = mergeGalleryReadReceipts(raw, {r'$g1': r'$g0'});
    expect(
      readersOf(fixed, r'$g0').contains(myId),
      isTrue,
      reason: 'после ремапа аватарка под видимым anchor',
    );
    expect(
      fixed.containsKey(r'$g1'),
      isFalse,
      reason: 'скрытый член больше не держит аватарку',
    );
    expect(avatarCountOf(fixed, myId), 1);
  });

  test(
    'ГАЛЕРЕЯ: собеседник, дочитавший до скрытого члена альбома, тоже садится '
    'на anchor — ровно по одной аватарке [ledger:RL-receipts-indicators]',
    () {
      // Роман дочитал до новейшего (скрытого) члена галереи.
      final room = buildRoom(
        receiptOthers: {
          _roman: {'e': r'$g1', 'ts': 310},
        },
      );
      final events = [
        galleryImg(room, r'$g1', myId, 300, gid: 'alb', i: 1, n: 2),
        galleryImg(room, r'$g0', myId, 200, gid: 'alb', i: 0, n: 2),
      ];
      final fixed = mergeGalleryReadReceipts(
        room.getReadReceiptsPerMessage(timelineOf(room, events)),
        {r'$g1': r'$g0'},
      );

      expect(
        readersOf(fixed, r'$g0'),
        containsAll(<String>[myId, _roman]),
        reason: 'и я, и Роман — под видимым anchor альбома',
      );
      expect(fixed.containsKey(r'$g1'), isFalse);
      expect(avatarCountOf(fixed, myId), 1);
      expect(avatarCountOf(fixed, _roman), 1);
    },
  );

  test('mergeGalleryReadReceipts: дедуп по пользователю (поздняя квитанция) + '
      'сортировка по ts [ledger:RL-receipts-indicators]', () {
    final room = buildRoom();
    final perMessage = <String, List<MessageReadReceipt>>{
      r'$anchor': [MessageReadReceipt(User(_roman, room: room), 100)],
      r'$hidden': [
        MessageReadReceipt(User(_roman, room: room), 300),
        MessageReadReceipt(User(_nadya, room: room), 200),
      ],
    };
    final merged = mergeGalleryReadReceipts(perMessage, {
      r'$hidden': r'$anchor',
    });

    final list = merged[r'$anchor']!;
    // Роман был и на anchor (ts100), и на скрытом (ts300) → одна запись,
    // поздняя (ts300).
    expect(list.where((r) => r.user.id == _roman).length, 1);
    expect(list.firstWhere((r) => r.user.id == _roman).ts, 300);
    // Сортировка по ts возр.: Надя (200) перед Романом (300).
    expect(list.map((r) => r.user.id).toList(), [_nadya, _roman]);
    expect(merged.containsKey(r'$hidden'), isFalse);
  });

  test(
    'mergeGalleryReadReceipts: без галереи — карта не копируется (no-op)',
    () {
      final perMessage = <String, List<MessageReadReceipt>>{r'$a': const []};
      // Пустой map скрытых членов.
      expect(
        identical(mergeGalleryReadReceipts(perMessage, const {}), perMessage),
        isTrue,
      );
      // Скрытые члены есть, но их нет в receipts — переносить нечего.
      expect(
        identical(
          mergeGalleryReadReceipts(perMessage, {r'$x': r'$y'}),
          perMessage,
        ),
        isTrue,
      );
    },
  );

  // ---- Заявка №60: единая граница участника (реакция = доказательство) ----
  // ledger:RL-receipts-side-no-height

  Event reaction(
    Room room,
    String id,
    String sender,
    String targetId,
    int ts, {
    bool redacted = false,
  }) => Event(
    eventId: id,
    senderId: sender,
    originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
    type: EventTypes.Reaction,
    content: {
      'm.relates_to': {
        'rel_type': RelationshipTypes.reaction,
        'event_id': targetId,
        'key': '👌',
      },
    },
    unsigned: redacted
        ? {
            'redacted_because': {
              'event_id': '\$redaction_$id',
              'sender': sender,
              'type': EventTypes.Redaction,
              'origin_server_ts': ts + 1,
              'content': <String, Object?>{},
            },
          }
        : null,
    room: room,
  );

  Event threadMsg(Room room, String id, String sender, int ts) => Event(
    eventId: id,
    senderId: sender,
    originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
    type: EventTypes.Message,
    content: {
      'msgtype': 'm.text',
      'body': id,
      'm.relates_to': {
        'rel_type': RelationshipTypes.thread,
        'event_id': 'root',
      },
    },
    room: room,
  );

  String? avatarEventOf(
    Map<String, List<MessageReadReceipt>> result,
    String userId,
  ) => result.entries
      .firstWhere(
        (e) => e.value.any((r) => r.user.id == userId),
        orElse: () => const MapEntry('', []),
      )
      .key;

  // Сценарий заявки: Надя прочитала (и написала) до nadya_own, затем Роман
  // написал roman_new, Надя поставила на него реакцию, а квитанции нет.
  List<Event> ticketScenario(Room room, {bool redacted = false}) => [
    reaction(room, 'r1', _nadya, 'roman_new', 700, redacted: redacted),
    msg(room, 'roman_new', _roman, 600),
    msg(room, 'my_voice', myId, 500),
    msg(room, 'nadya_own', _nadya, 400),
    msg(room, 'roman_old', _roman, 300),
  ];

  test('AC:RL-receipts-side-no-height/9 реакция на новое сообщение поднимает '
      'границу: аватарка под целью, ✓✓ у моих сообщений до цели, в списке '
      '«кто прочитал»', () {
    final room = buildRoom(
      receiptOthers: {
        _nadya: {'e': 'roman_old', 'ts': 310},
      },
    );
    final tl = timelineOf(room, ticketScenario(room));
    expect(
      avatarEventOf(room.getReadReceiptsPerMessage(tl), _nadya),
      'roman_new',
    );
    expect(room.readUpToTs(tl), greaterThanOrEqualTo(500));
    expect(
      room.getSeenByUsers(tl, eventId: 'my_voice').map((u) => u.id),
      contains(_nadya),
    );
  });

  for (final c in [
    (name: 'снятая (redacted) реакция', redacted: true, target: 'roman_new'),
  ]) {
    test('AC:RL-receipts-side-no-height/10 ${c.name} не двигает границу', () {
      final room = buildRoom(
        receiptOthers: {
          _nadya: {'e': 'roman_old', 'ts': 310},
        },
      );
      final tl = timelineOf(room, ticketScenario(room, redacted: c.redacted));
      expect(
        avatarEventOf(room.getReadReceiptsPerMessage(tl), _nadya),
        'nadya_own',
      );
      expect(
        room.getSeenByUsers(tl, eventId: 'my_voice').map((u) => u.id),
        isNot(contains(_nadya)),
      );
    });
  }

  test('AC:RL-receipts-side-no-height/10 реакция на сообщение старше границы — '
      'граница назад не уходит', () {
    final room = buildRoom(
      receiptOthers: {
        _nadya: {'e': 'roman_new', 'ts': 610},
      },
    );
    final events = [
      reaction(room, 'r1', _nadya, 'roman_old', 700),
      msg(room, 'roman_new', _roman, 600),
      msg(room, 'roman_old', _roman, 300),
    ];
    final tl = timelineOf(room, events);
    expect(
      avatarEventOf(room.getReadReceiptsPerMessage(tl), _nadya),
      'roman_new',
    );
  });

  test('AC:RL-receipts-side-no-height/10 цель вне загруженного окна — граница '
      'не поднимается до «сейчас» по ts реакции', () {
    final room = buildRoom(
      receiptOthers: {
        _nadya: {'e': 'roman_old', 'ts': 310},
      },
    );
    final events = [
      reaction(room, 'r1', _nadya, 'not_loaded', 900),
      msg(room, 'roman_new', _roman, 600),
      msg(room, 'roman_old', _roman, 300),
    ];
    final tl = timelineOf(room, events);
    expect(
      avatarEventOf(room.getReadReceiptsPerMessage(tl), _nadya),
      'roman_old',
    );
    // readUpToTs тут не показатель: roman_new написал сам Роман (он
    // «прочитал» его в момент отправки). Проверяем именно Надю.
    expect(
      room.getSeenByUsers(tl, eventId: 'roman_new').map((u) => u.id),
      isNot(contains(_nadya)),
    );
  });

  test(
    'AC:RL-receipts-side-no-height/10 реакция на сообщение в треде не двигает '
    'границу основной ленты',
    () {
      final room = buildRoom(
        receiptOthers: {
          _nadya: {'e': 'roman_old', 'ts': 310},
        },
      );
      final events = [
        reaction(room, 'r1', _nadya, 'in_thread', 900),
        threadMsg(room, 'in_thread', _roman, 800),
        msg(room, 'roman_new', _roman, 600),
        msg(room, 'roman_old', _roman, 300),
      ];
      final tl = timelineOf(room, events);
      expect(
        avatarEventOf(room.getReadReceiptsPerMessage(tl), _nadya),
        'roman_old',
      );
    },
  );

  test(
    'AC:RL-receipts-side-no-height/9 ответ собеседника ниже моего сообщения — '
    '✓✓ на моём и он в списке, даже без его квитанции (единая граница)',
    () {
      final room = buildRoom();
      final events = [
        msg(room, 'roman_reply', _roman, 600),
        msg(room, 'my_msg', myId, 500),
      ];
      final tl = timelineOf(room, events);
      expect(room.readUpToTs(tl), greaterThanOrEqualTo(500));
      expect(
        room.getSeenByUsers(tl, eventId: 'my_msg').map((u) => u.id),
        contains(_roman),
      );
    },
  );

  test('AC:RL-receipts-side-no-height/10 бот: его статус-сообщение и реакция '
      'после моего сообщения ✓✓ не ставят и в список не попадают (чат '
      'обращения поддержки — ✓✓ = прочитал специалист)', () {
    const bot = '@support:bots.example.invalid';
    final room = buildRoom();
    final events = [
      reaction(room, 'r_bot', bot, 'my_msg', 700),
      msg(room, 'bot_status', bot, 600),
      msg(room, 'my_msg', myId, 500),
    ];
    final tl = timelineOf(room, events);
    bool isBot(String id) => id == bot;
    expect(room.readUpToTs(tl, isAutomated: isBot), lessThan(500));
    expect(
      room
          .getSeenByUsers(tl, eventId: 'my_msg', isAutomated: isBot)
          .map((u) => u.id),
      isNot(contains(bot)),
    );
    // Автор под своим сообщением — как раньше (аватарка бота под статусом).
    expect(
      avatarEventOf(
        room.getReadReceiptsPerMessage(tl, isAutomated: isBot),
        bot,
      ),
      'bot_status',
    );
  });
}
