// Тесты advanceReadMarkerPastMine — продвижение сепаратора «Непрочитанное» за
// собственные сообщения (п.2.3). Главная жалоба пользователя: «метка
// непрочитанного оказывается ВЫШЕ моего сообщения», потому что сервер не шлёт
// m.read автору на его же событие и room.fullyRead отстаёт.

// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/utils/read_marker_logic.dart';

import 'test_client.dart';

const _me = '@me:example.invalid';
const _other = '@other:example.invalid';

void main() {
  late Client client;
  late Room room;

  setUp(() async {
    // isVisibleInGui читает AppSettings (hideRedactedEvents/hideUnknownEvents)
    // — без стора каждый вызов шумит в лог «Unable to fetch … from storage».
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!r:example.invalid', client: client);
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  // events идут новейшие→старейшие (как timeline.events в SDK).
  Event ev(String id, String sender) => Event(
    eventId: id,
    senderId: sender,
    originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
    type: EventTypes.Message,
    content: {'msgtype': 'm.text', 'body': id},
    room: room,
  );

  test('п.2.3: я написал, потом ответили двое чужих — метка встаёт НАД первым '
      'чужим, моё сообщение остаётся выше черты (прочитано)', () {
    // Хронология (старые→новые): X(read), M(мой), R1(чужой), R2(чужой).
    // timeline.events новейшие→старейшие:
    final events = [
      ev('R2', _other),
      ev('R1', _other),
      ev('M', _me),
      ev('X', _other), // room.fullyRead стоит здесь
    ];
    final result = advanceReadMarkerPastMine(events, 'X', _me);
    // Метка рисуется ПОД своим событием → ставим на M, черта ложится над R1.
    expect(result, 'M');
  });

  test('все события после метки — мои → метку снять (пустая строка)', () {
    // X(read), M1(мой), M2(мой).
    final events = [ev('M2', _me), ev('M1', _me), ev('X', _other)];
    expect(advanceReadMarkerPastMine(events, 'X', _me), '');
  });

  test('первое после метки — уже чужое непрочитанное → метку не двигаем', () {
    final events = [ev('R1', _other), ev('X', _other)];
    expect(advanceReadMarkerPastMine(events, 'X', _me), 'X');
  });

  test('метка на новейшем событии (idx 0) → ничего не делаем', () {
    final events = [ev('X', _other), ev('old', _other)];
    expect(advanceReadMarkerPastMine(events, 'X', _me), 'X');
  });

  test('пустой markerId → без изменений', () {
    final events = [ev('R1', _other)];
    expect(advanceReadMarkerPastMine(events, '', _me), '');
  });

  test('метка не найдена в окне → без изменений', () {
    final events = [ev('R1', _other), ev('R2', _other)];
    expect(advanceReadMarkerPastMine(events, 'missing', _me), 'missing');
  });

  test(
    'смешанная зона R2,M,R1: метка над САМЫМ СТАРЫМ непрочитанным чужим (R1)',
    () {
      // X(read), R1(чужой), M(мой), R2(чужой) — хронологически.
      final events = [
        ev('R2', _other),
        ev('M', _me),
        ev('R1', _other),
        ev('X', _other),
      ];
      // Самый старый непрочитанный чужой = R1 (idx 2). Сосед старше = X (idx 3).
      // Значит метка остаётся на X (черта уже над R1).
      expect(advanceReadMarkerPastMine(events, 'X', _me), 'X');
    },
  );

  // newestMessagesVisible — гейт квитанции не должен зависеть от залипшего
  // _scrolledUp, когда новейшее сообщение реально на экране. Симптом бага:
  // аватарка «прочитал» у собеседника появляется только после нашего ответа.
  group('newestMessagesVisible', () {
    test('контент помещается целиком (maxScrollExtent<=0) → видно', () {
      // Маленький чат: всё на экране. Даже если pixels шумит — новейшее видно.
      expect(
        newestMessagesVisible(
          maxScrollExtent: 0,
          pixels: 0,
          allowNewEvent: true,
        ),
        isTrue,
      );
      expect(
        newestMessagesVisible(
          maxScrollExtent: -5,
          pixels: 3,
          allowNewEvent: true,
        ),
        isTrue,
      );
    });

    test('скролл у самого низа (reverse-list, pixels~0) → видно', () {
      expect(
        newestMessagesVisible(
          maxScrollExtent: 5000,
          pixels: 0,
          allowNewEvent: true,
        ),
        isTrue,
      );
      expect(
        newestMessagesVisible(
          maxScrollExtent: 5000,
          pixels: 1.9,
          allowNewEvent: true,
        ),
        isTrue,
      );
    });

    test('прокручено в историю (большой pixels, есть extent) → НЕ видно', () {
      expect(
        newestMessagesVisible(
          maxScrollExtent: 5000,
          pixels: 800,
          allowNewEvent: true,
        ),
        isFalse,
      );
    });

    test('исторический контекст (allowNewEvent=false) → всегда НЕ видно', () {
      // Открыт контекст старого события — низ таймлайна не на экране.
      expect(
        newestMessagesVisible(
          maxScrollExtent: 0,
          pixels: 0,
          allowNewEvent: false,
        ),
        isFalse,
      );
    });
  });

  // openChatReadMarkerPlan — план квитанции при открытии чата. История:
  // LABA-1894 (ранний return без квитанции → залипший бейдж) → фикс «открытие =
  // квитанция на последнее» → запрос Саши Н. 2026-09-17 («увидел часть из 12,
  // вернулся — всё прочитано») → Telegram-модель: квитанция ОБЯЗАНА уйти, но
  // при скролле к сепаратору — на новейшее ВИДИМОЕ, а не на последнее.
  // ledger:RL-read-receipt-viewport-based
  group('openChatReadMarkerPlan', () {
    test('AC:RL-read-receipt-viewport-based/1 маркер уехал вверх (index>1): '
        'скролл к сепаратору + квитанция на ВИДИМОЕ (не на последнее) + '
        'сепаратор сохранён', () {
      final plan = openChatReadMarkerPlan(
        readMarkerEventIndex: 5,
        canMarkLastEvent: true,
      );
      expect(plan.scrollToDivider, isTrue);
      // Ядро Telegram-модели: «всё прочитано» при открытии НЕ шлём…
      expect(plan.markLastEvent, isFalse);
      // …но квитанция уходит — на новейшее видимое после позиционирования
      // (корень LABA-1894 — отсутствие квитанции вовсе — не возвращается).
      expect(plan.markVisibleAfterPosition, isTrue);
      expect(plan.preserveDivider, isTrue);
    });

    test('AC:RL-read-receipt-viewport-based/1 маркер у низа (index<=1): '
        'без скролла, квитанция на последнее, сепаратор снимается', () {
      for (final idx in [-1, 0, 1]) {
        final plan = openChatReadMarkerPlan(
          readMarkerEventIndex: idx,
          canMarkLastEvent: true,
        );
        expect(plan.scrollToDivider, isFalse, reason: 'idx=$idx');
        expect(plan.markLastEvent, isTrue, reason: 'idx=$idx');
        expect(plan.markVisibleAfterPosition, isFalse, reason: 'idx=$idx');
        expect(plan.preserveDivider, isFalse, reason: 'idx=$idx');
      }
    });

    test(
      'нет последнего события / historical context (canMarkLastEvent=false): '
      'последнее не помечаем, но скролл-решение по позиции сохраняется',
      () {
        final up = openChatReadMarkerPlan(
          readMarkerEventIndex: 9,
          canMarkLastEvent: false,
        );
        expect(up.scrollToDivider, isTrue);
        expect(up.markLastEvent, isFalse);
        expect(up.markVisibleAfterPosition, isTrue);
        expect(up.preserveDivider, isTrue);

        final bottom = openChatReadMarkerPlan(
          readMarkerEventIndex: 0,
          canMarkLastEvent: false,
        );
        expect(bottom.markLastEvent, isFalse);
        expect(bottom.markVisibleAfterPosition, isFalse);
      },
    );
  });

  // newestVisibleEventId — геометрия «увидено»: строка дочитана, когда её
  // НИЖНИЙ край на экране (Саша Н., 2026-10-28: 1 px верхушки первого
  // непрочитанного уходил в квитанцию сразу после открытия, отсечка вставала
  // после него). Новейшая — по индексу тега (reverse-list: меньший = новее),
  // а не по порядку в tagMap.
  // ledger:RL-read-receipt-viewport-based
  group('newestVisibleEventId', () {
    const viewport = Size(400, 600);
    VisibleTag tag(int index, String id, double top, double h) =>
        (index: index, eventId: id, rect: Rect.fromLTWH(0, top, 400, h));

    test('AC:RL-read-receipt-viewport-based/1 строки в cacheExtent не считаются; '
        'новейшее увиденное — первое по индексу, чей низ на экране', () {
      final tags = [
        // index 0..2 — новее, но лежат НИЖЕ экрана (reverse-list, cacheExtent).
        tag(0, 'E12', 900, 80),
        tag(1, 'E11', 800, 80),
        tag(2, 'E10', 600, 80), // верх ровно на границе — не видно
        tag(3, 'E9', 520, 80), // видна верхушка, низ 600 = край → увидено
        tag(4, 'E8', 400, 100),
        tag(5, 'E7', 300, 100),
        tag(6, 'E6', -50, 100), // частично сверху
        tag(7, 'E5', -200, 100), // выше экрана
      ];
      expect(newestVisibleEventId(tags, viewport), 'E9');
    });

    test('AC:RL-read-receipt-viewport-based/18 ∀ кейс: целиком видна → она; '
        'видна только верхушка → нет; низ виден при верхе выше экрана → она; '
        'длиннее экрана без видимого низа → нет', () {
      // Только верхушка первого непрочитанного (сценарий Саши) — не увидено,
      // ответ — прочитанное над ним.
      expect(
        newestVisibleEventId([
          tag(0, 'unread', 400, 900),
          tag(1, 'read', 100, 300),
        ], viewport),
        'read',
      );
      // Целиком на экране.
      expect(
        newestVisibleEventId([
          tag(0, 'unread', 400, 150),
          tag(1, 'read', 100, 300),
        ], viewport),
        'unread',
      );
      // Верх выше экрана, низ на экране — дочитано.
      expect(
        newestVisibleEventId([
          tag(0, 'below', 650, 80),
          tag(1, 'long', -700, 1200),
        ], viewport),
        'long',
      );
      // Длиннее экрана, низ за краем — не дочитано, более старых нет.
      expect(
        newestVisibleEventId([tag(0, 'long', -100, 1200)], viewport),
        isNull,
      );
      // Низ на границе с субпиксельной погрешностью — засчитан.
      expect(
        newestVisibleEventId([tag(0, 'edge', 500, 100.4)], viewport),
        'edge',
      );
    });

    test('порядок в tagMap не важен — решает индекс тега', () {
      final tags = [
        tag(5, 'E7', 300, 100),
        tag(3, 'E9', 100, 100),
        tag(4, 'E8', 200, 100),
      ];
      expect(newestVisibleEventId(tags, viewport), 'E9');
    });

    test('ничего не дочитано на экране → null', () {
      final tags = [tag(0, 'E1', 700, 50), tag(1, 'E0', -100, 50)];
      expect(newestVisibleEventId(tags, viewport), isNull);
      expect(newestVisibleEventId(const [], viewport), isNull);
    });

    test('строка нулевой высоты (скрытый член альбома) не «видна»', () {
      final tags = [tag(0, 'hidden', 100, 0), tag(1, 'E1', 100, 50)];
      expect(newestVisibleEventId(tags, viewport), 'E1');
    });
  });

  // dividerScrollPixels — куда встать при открытии, чтобы отсечка (низ
  // строки m.fully_read) оказалась у верха экрана. reverse-list: рост pixels
  // двигает контент вниз.
  // ledger:RL-read-receipt-viewport-based
  group('dividerScrollPixels', () {
    double at({
      required double pixels,
      required double bottom,
      double min = 0,
      double max = 5000,
    }) => dividerScrollPixels(
      pixels: pixels,
      dividerBottom: bottom,
      viewportHeight: 600,
      minScrollExtent: min,
      maxScrollExtent: max,
    );

    test('AC:RL-read-receipt-viewport-based/17 ∀ кейс: отсечка ниже цели → '
        'контент вверх; выше цели → вниз; длинное прочитанное (отсечка за '
        'нижним краем) → на цель; clamp у обоих краёв', () {
      final target = 600 * unreadDividerViewportFraction;
      // Обычный: центрированная строка, отсечка на 400 → pixels уменьшаются.
      expect(at(pixels: 1000, bottom: 400), 1000 + target - 400);
      // Отсечка выше цели → pixels растут.
      expect(at(pixels: 1000, bottom: 20), 1000 + target - 20);
      // Длинное прочитанное: отсечка на 1500 (за нижним краем).
      expect(at(pixels: 2000, bottom: 1500), 2000 + target - 1500);
      // Новый край: дальше низа ленты не уехать — отсечка останется ниже.
      expect(at(pixels: 100, bottom: 500), 0);
      // Старый край загруженной истории.
      expect(at(pixels: 4990, bottom: 10, max: 5000), 5000);
    });
  });

  // shouldScrollDownOnOwnEcho — своё действие → прокрутка к низу (запрос Саши Н.
  // 2026-09-17 «нажал кнопку, прокрутка к новому сообщению не сработала»).
  // Квантор «∀ источник» → мультикейс: композер / callback карточки / XL-кнопка;
  // негативные: реакция, правка, redaction, synced с другого устройства, чужое,
  // другая комната, тред↔главная лента.
  // ledger:RL-own-action-scrolls-to-bottom
  group('shouldScrollDownOnOwnEcho', () {
    Event echo({
      String sender = _me,
      EventStatus status = EventStatus.sending,
      String type = EventTypes.Message,
      Map<String, dynamic>? content,
      Room? inRoom,
    }) => Event(
      eventId: 'txn-${content.hashCode}',
      senderId: sender,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
      type: type,
      content: content ?? {'msgtype': 'm.text', 'body': 'hi'},
      status: status,
      room: inRoom ?? room,
    );

    bool call(Event e, {String? threadId}) => shouldScrollDownOnOwnEcho(
      e,
      myUserId: _me,
      roomId: room.id,
      activeThreadId: threadId,
    );

    test('AC:RL-own-action-scrolls-to-bottom/1 ∀источник ∈ {композер, callback '
        'карточки com.liza.miniapp.callback, XL-кнопка (текст-номер), стикер} → '
        'скроллим', () {
      final cases = <String, Event>{
        'композер': echo(),
        'композер reply': echo(
          content: {
            'msgtype': 'm.text',
            'body': 'reply',
            'm.relates_to': {
              'm.in_reply_to': {'event_id': '\$parent'},
            },
          },
        ),
        'callback карточки': echo(
          content: {
            'msgtype': 'com.liza.miniapp.callback',
            'body': 'Выбрано: Мои обращения',
            'button_id': 'support.menu.my',
            'm.relates_to': {
              'rel_type': 'com.liza.miniapp.answer',
              'event_id': '\$card',
            },
          },
        ),
        'XL-кнопка': echo(content: {'msgtype': 'm.text', 'body': '2'}),
        'стикер': echo(
          type: EventTypes.Sticker,
          content: {'body': 's', 'url': 'mxc://x/y'},
        ),
      };
      for (final entry in cases.entries) {
        expect(call(entry.value), isTrue, reason: entry.key);
      }
    });

    test(
      'AC:RL-own-action-scrolls-to-bottom/2 ∀тип ∈ {реакция, правка, redaction, '
      'своё synced (другое устройство), чужое, другая комната} → НЕ скроллим',
      () {
        final other = Room(id: '!other:example.invalid', client: client);
        final cases = <String, Event>{
          'реакция': echo(
            type: EventTypes.Reaction,
            content: {
              'm.relates_to': {
                'rel_type': 'm.annotation',
                'event_id': '\$old',
                'key': '👍',
              },
            },
          ),
          'правка': echo(
            content: {
              'msgtype': 'm.text',
              'body': '* fixed',
              'm.new_content': {'msgtype': 'm.text', 'body': 'fixed'},
              'm.relates_to': {'rel_type': 'm.replace', 'event_id': '\$old'},
            },
          ),
          'redaction': echo(
            type: EventTypes.Redaction,
            content: {'redacts': '\$old'},
          ),
          'своё synced': echo(status: EventStatus.synced),
          'своё sent': echo(status: EventStatus.sent),
          'чужое sending': echo(sender: _other),
          'другая комната': echo(inRoom: other),
        };
        for (final entry in cases.entries) {
          expect(call(entry.value), isFalse, reason: entry.key);
        }
      },
    );

    test('контекст: тред-ответ не скроллит главную ленту и наоборот', () {
      final threadReply = echo(
        content: {
          'msgtype': 'm.text',
          'body': 't',
          'm.relates_to': {'rel_type': 'm.thread', 'event_id': '\$root'},
        },
      );
      expect(call(threadReply), isFalse);
      expect(call(threadReply, threadId: '\$root'), isTrue);
      expect(call(threadReply, threadId: '\$otherRoot'), isFalse);
      expect(call(echo(), threadId: '\$root'), isFalse);
    });
  });

  // scrollControllerUpdateAction — решение scroll-listener'а по метрикам. Баг
  // «экран трясётся в цикле при входе в чат с непрочитанным»: во время
  // программной прокрутки к сепаратору «Непрочитанное» (scrollToIndex) listener
  // дёргался на каждом кадре анимации и в зоне pixels<1 звал setReadMarker,
  // который сбрасывал readMarkerEventId → сепаратор (~48px) исчезал → геометрия
  // менялась → scrollToIndex прыгал заново → незатухающий цикл. Фикс: во время
  // isAutoScrolling подавляем layout-меняющие эффекты.
  group('scrollControllerUpdateAction', () {
    test(
      'обычный скролл вверх (pixels>2, не scrolledUp) → показать кнопку «вниз»',
      () {
        expect(
          scrollControllerUpdateAction(
            maxScrollExtent: 5000,
            pixels: 800,
            allowNewEvent: true,
            scrolledUp: false,
            isAutoScrolling: false,
          ),
          ScrollUpdateAction.setScrolledUpTrue,
        );
      },
    );

    test(
      'обычный докрут к низу (pixels<1, был scrolledUp) → сброс + маркер',
      () {
        expect(
          scrollControllerUpdateAction(
            maxScrollExtent: 5000,
            pixels: 0,
            allowNewEvent: true,
            scrolledUp: true,
            isAutoScrolling: false,
          ),
          ScrollUpdateAction.setScrolledUpFalseAndMark,
        );
      },
    );

    test(
      'контент помещается целиком (maxScrollExtent<=0) → досыл маркера у низа',
      () {
        expect(
          scrollControllerUpdateAction(
            maxScrollExtent: 0,
            pixels: 0,
            allowNewEvent: true,
            scrolledUp: false,
            isAutoScrolling: false,
          ),
          ScrollUpdateAction.markAtBottom,
        );
      },
    );

    test('исторический контекст (allowNewEvent=false) → показать кнопку', () {
      expect(
        scrollControllerUpdateAction(
          maxScrollExtent: 5000,
          pixels: 0,
          allowNewEvent: false,
          scrolledUp: false,
          isAutoScrolling: false,
        ),
        ScrollUpdateAction.setScrolledUpTrue,
      );
    });

    // Ядро фикса цикла: пока идёт программный авто-скролл к маркеру, listener
    // НЕ должен трогать layout (ни сброс scrolledUp+маркер, ни досыл маркера),
    // иначе сепаратор исчезает и scrollToIndex прыгает заново. Кнопку «вниз»
    // показывать тоже не нужно — авто-скролл сам довезёт до цели.
    test('АВТО-СКРОЛЛ, зона pixels<1 — НЕ сбрасываем и НЕ шлём маркер', () {
      expect(
        scrollControllerUpdateAction(
          maxScrollExtent: 5000,
          pixels: 0,
          allowNewEvent: true,
          scrolledUp: true,
          isAutoScrolling: true,
        ),
        ScrollUpdateAction.none,
      );
    });

    test('АВТО-СКРОЛЛ, maxScrollExtent<=0 — НЕ досылаем маркер', () {
      expect(
        scrollControllerUpdateAction(
          maxScrollExtent: 0,
          pixels: 0,
          allowNewEvent: true,
          scrolledUp: false,
          isAutoScrolling: true,
        ),
        ScrollUpdateAction.none,
      );
    });

    test('АВТО-СКРОЛЛ, pixels>2 — НЕ дёргаем setState/layout', () {
      expect(
        scrollControllerUpdateAction(
          maxScrollExtent: 5000,
          pixels: 800,
          allowNewEvent: true,
          scrolledUp: false,
          isAutoScrolling: true,
        ),
        ScrollUpdateAction.none,
      );
    });
  });

  // readableForeground — когда квитанции «прочитано» вообще можно слать.
  // ∀ lifecycle × desktop × lock-screen; lock-screen ветка появилась вместе с
  // серверной read-grace (квитанция с залоченного Мака глушила бы пуш).
  // С 2026-09-18 (заявка №31, круг 4) desktop-inactive даёт только ЧАСТИЧНУЮ
  // квитанцию — полная ждёт фокуса; таблица целиком — в
  // desktop_unfocused_no_full_read_test.dart (RL-desktop-unfocused-no-full-read).
  // ledger:RL-read-receipt-viewport-based
  group('readableForeground', () {
    test(
      'AC:RL-read-receipt-viewport-based/5 ∀ {resumed → full; desktop-inactive '
      'без блокировки → partialOnly; desktop-inactive + screenLocked → none; '
      'mobile inactive → none; paused/hidden/detached → none}',
      () {
        ReadableForeground call(
          AppLifecycleState? s, {
          bool desktop = true,
          bool locked = false,
        }) => readableForeground(
          lifecycle: s,
          isDesktop: desktop,
          screenLocked: locked,
        );
        expect(call(AppLifecycleState.resumed), ReadableForeground.full);
        expect(
          call(AppLifecycleState.resumed, locked: true),
          ReadableForeground.full,
          reason: 'resumed = окно в фокусе, экран точно не заблокирован',
        );
        expect(
          call(AppLifecycleState.inactive),
          ReadableForeground.partialOnly,
        );
        expect(
          call(AppLifecycleState.inactive, locked: true),
          ReadableForeground.none,
        );
        expect(
          call(AppLifecycleState.inactive, desktop: false),
          ReadableForeground.none,
        );
        for (final s in [
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.detached,
          null,
        ]) {
          expect(call(s), ReadableForeground.none, reason: '$s');
        }
      },
    );
  });

  // ownEchoScrollAction — реакция на свой echo ∀ состояние ленты. Кейс
  // `timeline == null` — GlitchTip #2042 (сборка 3762): SDK на одну отправку
  // файла шлёт несколько echo `sending`, а первый уже обнулил timeline через
  // scrollDown() → второй звал scrollDown() на null → `timeline!` → каскад.
  // ledger:RL-own-action-scrolls-to-bottom
  group('ownEchoScrollAction', () {
    test(
      'AC:RL-own-action-scrolls-to-bottom/6 ∀ {live → отложенный прыжок; '
      'исторический контекст → перезагрузка; лента грузится (null) → ничего}',
      () {
        expect(
          ownEchoScrollAction(allowNewEvent: true),
          OwnEchoScrollAction.deferJumpToBottom,
        );
        expect(
          ownEchoScrollAction(allowNewEvent: false),
          OwnEchoScrollAction.reloadToLiveEnd,
        );
        expect(
          ownEchoScrollAction(allowNewEvent: null),
          OwnEchoScrollAction.none,
          reason:
              'null = перезагрузка/первичная загрузка, scrollDown() звать нельзя',
        );
      },
    );
  });
}
