import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Enter в поле ввода сообщения — единое правило для `ChatPage` и чернового
/// личного чата `DraftChatPage` (до 2026-10-19 черновик правила не имел, и
/// Enter там вставлял перенос строки, пока первое сообщение не уйдёт
/// самолётиком).
///
/// Возвращает `null`, когда решение за вызывающим: клавиша не Enter, либо
/// mobile (там у `ChatPage` свои правила продолжения списков).
/// `ignored` — `TextField` сам вставит `\n` или IME подтвердит кандидата.
/// `handled` — Enter съеден; отправка только на нажатии, повтор и отпускание
/// не шлют второе сообщение.
KeyEventResult? composerEnterKey(
  KeyEvent evt,
  TextEditingValue value, {
  required bool isMobile,
  required VoidCallback onSend,
}) {
  // По logicalKey, а не keyLabel: keyLabel зависит от раскладки/IME — на
  // macOS c RU-раскладкой может прийти не "Enter".
  final isEnter =
      evt.logicalKey == LogicalKeyboardKey.enter ||
      evt.logicalKey == LogicalKeyboardKey.numpadEnter;
  if (!isEnter) return null;

  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isShiftPressed ||
      keyboard.isAltPressed ||
      keyboard.isMetaPressed ||
      keyboard.isControlPressed) {
    return KeyEventResult.ignored;
  }

  if (isMobile) return null;

  // Enter при наборе через IME (японский, китайский) подтверждает кандидата —
  // отправка здесь ушла бы с недописанным словом.
  if (value.composing.isValid && !value.composing.isCollapsed) {
    return KeyEventResult.ignored;
  }

  if (evt is KeyDownEvent) onSend();
  return KeyEventResult.handled;
}
