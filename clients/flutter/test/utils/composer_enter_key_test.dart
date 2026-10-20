// ledger:RL-direct-chat-draft-on-first-send
// AC:RL-direct-chat-draft-on-first-send/10
// AC:RL-direct-chat-draft-on-first-send/11
// AC:RL-direct-chat-draft-on-first-send/12
// AC:RL-direct-chat-draft-on-first-send/13
// AC:RL-direct-chat-draft-on-first-send/14
//
// Общее правило Enter композера (ChatPage и черновой личный чат). Модификаторы
// берутся из HardwareKeyboard, поэтому зажимаем их настоящими key-событиями
// через tester, а решение спрашиваем у функции напрямую.
//
// Red-proof: убрать проверку композиции IME → AC-12 отправит недописанное;
// слать на любом событии, а не только KeyDown → AC-13 даст две отправки.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/composer_enter_key.dart';

const _down = KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.enter,
  logicalKey: LogicalKeyboardKey.enter,
  timeStamp: Duration.zero,
);
const _repeat = KeyRepeatEvent(
  physicalKey: PhysicalKeyboardKey.enter,
  logicalKey: LogicalKeyboardKey.enter,
  timeStamp: Duration.zero,
);
const _up = KeyUpEvent(
  physicalKey: PhysicalKeyboardKey.enter,
  logicalKey: LogicalKeyboardKey.enter,
  timeStamp: Duration.zero,
);
const _numpadDown = KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.numpadEnter,
  logicalKey: LogicalKeyboardKey.numpadEnter,
  timeStamp: Duration.zero,
);

const _text = TextEditingValue(text: 'привет');

void main() {
  late int sends;
  setUp(() => sends = 0);
  void onSend() => sends++;

  test('AC-10: desktop, Enter и numpad Enter без модификаторов — одна отправка '
      'на событие, handled', () {
    for (final evt in const [_down, _numpadDown]) {
      sends = 0;
      final r = composerEnterKey(evt, _text, isMobile: false, onSend: onSend);
      expect(r, KeyEventResult.handled, reason: '${evt.logicalKey}');
      expect(sends, 1, reason: '${evt.logicalKey}');
    }
  });

  testWidgets('AC-11: любой модификатор + Enter — перенос строки (ignored), '
      'отправки нет, на desktop и mobile', (tester) async {
    for (final modifier in const [
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      for (final isMobile in const [false, true]) {
        final r = composerEnterKey(
          _down,
          _text,
          isMobile: isMobile,
          onSend: onSend,
        );
        expect(r, KeyEventResult.ignored, reason: '$modifier mobile=$isMobile');
      }
      await tester.sendKeyUpEvent(modifier);
    }
    expect(sends, 0);
  });

  test('AC-12: Enter во время набора через IME не отправляет', () {
    const composing = TextEditingValue(
      text: 'にほん',
      composing: TextRange(start: 0, end: 3),
    );
    final r = composerEnterKey(
      _down,
      composing,
      isMobile: false,
      onSend: onSend,
    );
    expect(r, KeyEventResult.ignored);
    expect(sends, 0);
  });

  test('AC-13: удержание и отпускание Enter не отправляют повторно, но Enter '
      'съеден (без переноса строки)', () {
    for (final evt in const [_repeat, _up]) {
      final r = composerEnterKey(evt, _text, isMobile: false, onSend: onSend);
      expect(r, KeyEventResult.handled, reason: '${evt.runtimeType}');
    }
    expect(sends, 0);
  });

  test('AC-14: mobile и не-Enter — решение за вызывающим (null)', () {
    expect(
      composerEnterKey(_down, _text, isMobile: true, onSend: onSend),
      isNull,
    );
    const keyA = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      timeStamp: Duration.zero,
    );
    expect(
      composerEnterKey(keyA, _text, isMobile: false, onSend: onSend),
      isNull,
    );
    expect(sends, 0);
  });
}
