// Полная квитанция «прочитано» на десктопе — только из окна в фокусе
// (заявка №31, четвёртый круг, 2026-09-18).
//
// Прод-факт (nginx prod, Мак Саши): сообщение пришло по живому /sync за 1 с,
// окно Лизы было частично видно и НЕ в фокусе (`inactive`), клиент в ту же
// секунду отправил полную квитанцию → `cancelNotification` снял локальный
// баннер из sync → человек узнал о сообщении от APNs через 2 минуты, а
// отправитель видел ложное «прочитано». 12 из 45 квитанций за день — такие.
//
// Движок Flutter macOS шлёт `hidden`, только когда не видно НИ ОДНОГО пикселя
// окна; торчащее из-под браузера краем окно — `inactive`. Поэтому `inactive`
// ≠ «читает»: из него допустима лишь частичная квитанция по явной прокрутке.
//
// Архитектура стража (почему не реплика): AC-1..AC-3 зовут ПРОД-предикаты
// `readableForeground`/`readMarkerGate` (единственный экземпляр логики,
// прод-вызов — chat.dart `_sendReadMarkerNow`). Полную `ChatPage` в
// unit-окружении не поднять (нужны Matrix.of/роутер/таймлайн — см.
// content_protection_holes_test), поэтому ПРОВОДКА защищена статическим
// ratchet-стражем по исходникам (AC-4, AC-6): гейт реально вызывается, оба
// сайта баннера читают тот же предикат, observer снимается в dispose.
// Device-приёмка (баннер ≥30 с при не-key окне) — manual AC-7 в реестре.
//
// ledger:RL-desktop-unfocused-no-full-read

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/read_marker_logic.dart';

void main() {
  ReadableForeground readable(
    AppLifecycleState? s, {
    bool desktop = true,
    bool locked = false,
  }) => readableForeground(
    lifecycle: s,
    isDesktop: desktop,
    screenLocked: locked,
  );

  // AC:RL-desktop-unfocused-no-full-read/1
  test('AC-1 ∀ lifecycle × платформа × lock: full только resumed, partialOnly '
      'только desktop-inactive без блокировки, остальное none', () {
    const all = [...AppLifecycleState.values, null];
    for (final s in all) {
      for (final desktop in [true, false]) {
        for (final locked in [true, false]) {
          final expected = s == AppLifecycleState.resumed
              ? ReadableForeground.full
              : (desktop && s == AppLifecycleState.inactive && !locked)
              ? ReadableForeground.partialOnly
              : ReadableForeground.none;
          expect(
            readable(s, desktop: desktop, locked: locked),
            expected,
            reason: 'lifecycle=$s desktop=$desktop locked=$locked',
          );
        }
      }
    }
    // Ядро дефекта: desktop-inactive НЕ даёт full — red-proof: подмена
    // `partialOnly → full` в readableForeground роняет именно этот expect.
    expect(
      readable(AppLifecycleState.inactive),
      isNot(ReadableForeground.full),
      reason: 'из окна без фокуса полная квитанция снимала баннер через 0,3 с',
    );
  });

  // AC:RL-desktop-unfocused-no-full-read/2
  test('AC-2 гейт: desktop-inactive + полная квитанция (низ ленты, stick-to-'
      'bottom при приходе ≥3 сообщений) → deferFull, не send', () {
    final gate = readMarkerGate(
      readable: readable(AppLifecycleState.inactive),
      isFull: true,
    );
    expect(gate, ReadMarkerGate.deferFull);
    expect(
      gate,
      isNot(ReadMarkerGate.send),
      reason:
          'send здесь = POST /read_markers + cancelNotification из окна, '
          'на которое никто не смотрит',
    );
    // Пришло ещё сообщение — по-прежнему низ ленты, по-прежнему откладываем:
    // квантор «≥3 подряд» из задания — гейт не зависит от числа событий.
    for (var i = 0; i < 3; i++) {
      expect(
        readMarkerGate(
          readable: readable(AppLifecycleState.inactive),
          isFull: true,
        ),
        ReadMarkerGate.deferFull,
        reason: 'сообщение №${i + 1}',
      );
    }
    // Окно получило фокус → полная квитанция уходит (resumed зовёт
    // setReadMarker сам — отдельный триггер «стало видно» намеренно не вводим).
    expect(
      readMarkerGate(
        readable: readable(AppLifecycleState.resumed),
        isFull: true,
      ),
      ReadMarkerGate.send,
    );
  });

  // AC:RL-desktop-unfocused-no-full-read/3
  test('AC-3 гейт: desktop-inactive + прокрутка на событие ≠ lastEvent → send '
      '(жест = внимание); none → blocked при любой квитанции', () {
    expect(
      readMarkerGate(
        readable: readable(AppLifecycleState.inactive),
        isFull: false,
      ),
      ReadMarkerGate.send,
    );
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
      null,
    ]) {
      for (final isFull in [true, false]) {
        expect(
          readMarkerGate(readable: readable(s), isFull: isFull),
          ReadMarkerGate.blocked,
          reason: 'lifecycle=$s isFull=$isFull',
        );
      }
    }
    expect(
      readMarkerGate(
        readable: readable(AppLifecycleState.inactive, locked: true),
        isFull: false,
      ),
      ReadMarkerGate.blocked,
      reason: 'lock screen — читать некому, даже частичную не шлём',
    );
  });

  // AC:RL-desktop-unfocused-no-full-read/5
  test('AC-5 Windows/Linux: тот же desktop-предикат — из окна без фокуса '
      'полная квитанция откладывается', () {
    // isDesktop общий для macOS/Windows/Linux — правило единое, зеркала
    // блокировки на Windows нет → locked=false.
    expect(
      readMarkerGate(
        readable: readable(AppLifecycleState.inactive, locked: false),
        isFull: true,
      ),
      ReadMarkerGate.deferFull,
    );
  });

  group('проводка (статический ratchet по исходникам)', () {
    final chat = File('lib/pages/chat/chat.dart').readAsStringSync();
    final pushHelper = File('lib/utils/push_helper.dart').readAsStringSync();
    final localNotif = File(
      'lib/widgets/local_notifications_extension.dart',
    ).readAsStringSync();

    // AC:RL-desktop-unfocused-no-full-read/4
    test('AC-4 квитанция и оба сайта баннера читают ОДИН предикат '
        'readableForeground; голого `lifecycleState == resumed` у '
        'pushInActiveRoomFor нет', () {
      expect(
        chat.replaceAll(RegExp(r'\s+'), ' ').contains(
          'readMarkerGate( readable: readable, isFull: isFull,',
        ),
        isTrue,
        reason:
            '_sendReadMarkerNow обязан спрашивать гейт — иначе AC-1..3 '
            'зелёные на функции, которую никто не зовёт',
      );
      // Сайт баннера: аргумент `resumed:` берётся из readableForeground,
      // а не из прямого сравнения lifecycle — иначе предикаты разойдутся и
      // вернётся «баннер показан при inactive → снят квитанцией при inactive».
      for (final (name, src) in [
        ('push_helper.dart', pushHelper),
        ('local_notifications_extension.dart', localNotif),
      ]) {
        final call = src.indexOf('pushInActiveRoomFor(');
        expect(call, greaterThanOrEqualTo(0), reason: name);
        final tail = src.substring(call, src.indexOf(');', call));
        expect(
          tail.contains('ReadableForeground.full'),
          isTrue,
          reason: '$name: resumed должен выводиться из readableForeground',
        );
        expect(
          tail.contains('lifecycleState == AppLifecycleState.resumed'),
          isFalse,
          reason:
              '$name: прямое сравнение lifecycle у pushInActiveRoomFor — '
              'вторая копия предиката «смотрит»',
        );
      }
    });

    // AC:RL-desktop-unfocused-no-full-read/6
    test('AC-6 ChatController снимает lifecycle-observer в dispose (парно к '
        'addObserver в initState)', () {
      final initIdx = chat.indexOf(
        'WidgetsBinding.instance.addObserver(this);',
      );
      expect(initIdx, greaterThanOrEqualTo(0));
      // Первый dispose() после initState — ChatController.dispose; второй
      // класс в файле (chat_view state) уже был парным.
      final disposeIdx = chat.indexOf('void dispose() {', initIdx);
      final disposeEnd = chat.indexOf('super.dispose();', disposeIdx);
      final body = chat.substring(disposeIdx, disposeEnd);
      expect(
        body.contains('WidgetsBinding.instance.removeObserver(this);'),
        isTrue,
        reason:
            'без removeObserver каждый закрытый чат остаётся слушателем и '
            'на каждом resumed зовёт setReadMarker (дубли POST)',
      );
    });
  });
}
