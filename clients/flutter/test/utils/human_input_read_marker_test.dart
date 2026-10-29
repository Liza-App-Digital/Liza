// Заявка №60: действие человека в чате (отправка, реакция, кнопка бота) —
// доказательство внимания. Из десктопного окна без фокуса (`inactive`) полная
// квитанция после такого действия уходит сразу, а не ждёт `resumed`. Свёрнутое
// окно / lock screen (`none`) не повышается никогда, и эхо без человека
// (автоповтор, XL-ключ, синк) действием не считается.
// Спека: docs/superpowers/specs/2026-10-28-ticket60-read-receipts-side-and-action-proof-design.md
//
// ledger:RL-receipts-side-no-height

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/read_marker_logic.dart';

void main() {
  tearDown(HumanInputTracker.reset);

  group('AC:RL-receipts-side-no-height/11 гейт с действием человека', () {
    for (final c in const [
      (
        name: 'inactive + ввод → полная уходит',
        readable: ReadableForeground.partialOnly,
        isFull: true,
        input: true,
        gate: ReadMarkerGate.send,
      ),
      (
        name: 'inactive без ввода → полная откладывается (как раньше)',
        readable: ReadableForeground.partialOnly,
        isFull: true,
        input: false,
        gate: ReadMarkerGate.deferFull,
      ),
      (
        name: 'inactive + ввод → частичная уходит',
        readable: ReadableForeground.partialOnly,
        isFull: false,
        input: true,
        gate: ReadMarkerGate.send,
      ),
      (
        name: 'свёрнуто/lock screen + ввод → блок (read-grace)',
        readable: ReadableForeground.none,
        isFull: true,
        input: true,
        gate: ReadMarkerGate.blocked,
      ),
      (
        name: 'свёрнуто/lock screen + ввод, частичная → блок',
        readable: ReadableForeground.none,
        isFull: false,
        input: true,
        gate: ReadMarkerGate.blocked,
      ),
      (
        name: 'resumed + ввод → уходит',
        readable: ReadableForeground.full,
        isFull: true,
        input: true,
        gate: ReadMarkerGate.send,
      ),
    ]) {
      test(c.name, () {
        expect(
          readMarkerGate(
            readable: c.readable,
            isFull: c.isFull,
            humanInput: c.input,
          ),
          c.gate,
        );
      });
    }

    test('ввод свежий 5 с, дальше — как без ввода', () {
      final t0 = DateTime(2026, 10, 28, 12);
      HumanInputTracker.mark('!r', now: t0);
      expect(
        HumanInputTracker.isRecent(
          '!r',
          now: t0.add(const Duration(seconds: 5)),
        ),
        isTrue,
      );
      expect(
        HumanInputTracker.isRecent(
          '!r',
          now: t0.add(const Duration(seconds: 6)),
        ),
        isFalse,
      );
      expect(HumanInputTracker.isRecent('!other', now: t0), isFalse);
    });

    test(
      'mark публикует roomId — ChatController шлёт по нему квитанцию',
      () async {
        final got = <String>[];
        final sub = HumanInputTracker.onInput.listen(got.add);
        HumanInputTracker.mark('!r');
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        expect(got, ['!r']);
      },
    );
  });

  group('AC:RL-receipts-side-no-height/12 кто взводит «действие человека»', () {
    String read(String path) => File(path).readAsStringSync();
    final chat = read('lib/pages/chat/chat.dart');
    String body(String src, String opener) {
      final start = src.indexOf(opener);
      expect(start, isNot(-1), reason: opener);
      final next = src.indexOf(
        RegExp(r'\n  [A-Za-z_<>?, ]+\(.*\) (async )?\{'),
        start + 1,
      );
      return src.substring(start, next < 0 ? src.length : next);
    }

    test(
      'UI-точки взводят: композер, реакция, голосовое, чип, кнопка бота',
      () {
        expect(
          body(chat, 'Future<void> send() async {'),
          contains('HumanInputTracker.mark(roomId)'),
        );
        expect(
          body(chat, 'void toggleReaction(Event event, String emoji) {'),
          contains('HumanInputTracker.mark(roomId)'),
        );
        expect(
          body(chat, 'Future<void> onVoiceMessageSend('),
          contains('HumanInputTracker.mark(roomId)'),
        );
        expect(
          read('lib/pages/chat/events/message_reactions.dart'),
          contains('HumanInputTracker.mark(event.room.id)'),
        );
        expect(
          read('lib/utils/bot_callback.dart'),
          contains('HumanInputTracker.mark(room.id)'),
        );
      },
    );

    test('эхо и автоповтор действием НЕ считаются', () {
      expect(
        body(chat, 'void _onOwnEcho(Event _) {'),
        isNot(contains('HumanInputTracker.mark')),
      );
      expect(
        read('lib/utils/failed_send_retry_service.dart'),
        isNot(contains('HumanInputTracker')),
      );
    });

    test('реакция шлёт квитанцию через подписку, без прокрутки', () {
      final compact = chat.replaceAll(RegExp(r'\s+'), ' ');
      final sub = compact.indexOf(
        '_humanInputSubscription = HumanInputTracker.onInput',
      );
      expect(sub, isNot(-1));
      final handler = compact.substring(sub, compact.indexOf('});', sub));
      expect(handler, contains('setReadMarker()'));
      expect(handler, isNot(contains('scrollDown')));
      expect(
        compact,
        contains('humanInput: HumanInputTracker.isRecent(roomId)'),
      );
    });
  });

  group('AC:RL-receipts-side-no-height/13 лог подавления после ввода', () {
    test('та же причина — не чаще раза в 60 с, смена причины — сразу', () {
      final t = SuppressedReadMarkerLogThrottle();
      final t0 = DateTime(2026, 10, 28, 12);
      expect(t.shouldLog('lifecycle-defer', now: t0), isTrue);
      expect(
        t.shouldLog(
          'lifecycle-defer',
          now: t0.add(const Duration(seconds: 30)),
        ),
        isFalse,
      );
      expect(
        t.shouldLog('positioning', now: t0.add(const Duration(seconds: 31))),
        isTrue,
      );
      expect(
        t.shouldLog('positioning', now: t0.add(const Duration(seconds: 92))),
        isTrue,
      );
    });

    test('каждый гейт _sendReadMarkerNow пишет свою причину', () {
      final chat = File('lib/pages/chat/chat.dart').readAsStringSync();
      for (final reason in const [
        'positioning',
        'geometry-null',
        'banner',
        'lifecycle-none',
        'lifecycle-defer',
      ]) {
        expect(chat, contains("_logSuppressedAfterInput('$reason')"));
      }
      expect(
        File('lib/widgets/matrix.dart').readAsStringSync(),
        contains("'[lifecycle] "),
      );
    });
  });
}
