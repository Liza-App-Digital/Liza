import 'package:flutter/material.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';

/// Футер сообщения в Liza-стиле: HH:MM у КАЖДОГО сообщения, а у своих —
/// рядом со временем индикатор доставки/прочтения (часики → ✓ → ✓✓). Раньше
/// время рисовалось только центрированной плашкой-разделителем над группой
/// (см. `displayTime` в message.dart), из-за чего у большинства сообщений
/// времени видно не было.
///
/// Виджет намеренно «глупый» (принимает уже посчитанные примитивы, не `Event`),
/// чтобы golden-страж `ledger:RL-message-time` рендерил РЕАЛЬНЫЙ путь без
/// подъёма Matrix Client (тот в testWidgets вешает пул) — как у
/// `bot_miniapp_buttons`. Строку времени и статус считает `Message.build`.
///
/// Два режима:
/// - inline — строка под контентом в пузыре (текст/аудио/файл/подпись). Цвет
///   приглушённый ([color]).
/// - overlay — плашка поверх медиа (одиночное фото/видео/стикер): тёмный фон,
///   белый текст/иконки, читаемый на любой картинке (как в Liza).
class MessageTime extends StatelessWidget {
  /// Уже локализованная строка времени (HH:MM или h:mm a) — считается вызывающей
  /// стороной через `originServerTs.localizedTimeOfDay(context)`.
  final String time;

  /// Своё сообщение — показываем индикатор доставки/прочтения справа от времени.
  final bool showStatus;

  final bool isError;
  final bool isSendingFile;
  final bool isSending;
  final bool isRead;
  final bool isDraft;

  /// Плашка-оверлей поверх медиа (тёмный фон, белый текст) вместо inline-строки.
  final bool overlay;

  /// Базовый (приглушённый) цвет времени в inline-режиме. В overlay игнорируется
  /// — там всегда белый поверх тёмной плашки.
  final Color color;

  const MessageTime({
    required this.time,
    required this.color,
    this.showStatus = false,
    this.isError = false,
    this.isSendingFile = false,
    this.isSending = false,
    this.isRead = false,
    this.isDraft = false,
    this.overlay = false,
    super.key,
  });

  Widget _status(Color glyphColor) {
    if (isError) {
      return Icon(Icons.error, size: 14, color: glyphColor);
    }
    if (isSendingFile) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: glyphColor),
      );
    }
    // Глиф красим цветом футера ([glyphColor]) — на цветном пузыре своего
    // сообщения themed `colorScheme.primary` (для «прочитано») сливается с фоном.
    // Sent/read различаются одной/двумя галочками, как в Liza, а не цветом.
    return MessageReadIndicator(
      isSending: isSending,
      isRead: isRead,
      color: glyphColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final glyphColor = overlay ? Colors.white : color;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (isDraft) ...[
          Text(
            L10n.of(context).botDraft,
            style: TextStyle(fontSize: 11, color: glyphColor),
          ),
          const SizedBox(width: 4),
        ],
        Text(
          time,
          style: TextStyle(
            fontSize: 11 * AppSettings.fontSizeFactor.value,
            color: glyphColor,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (showStatus) ...[const SizedBox(width: 3), _status(glyphColor)],
      ],
    );

    if (!overlay) return row;

    return Material(
      color: Colors.black.withAlpha(140),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: row,
      ),
    );
  }
}

/// Иконка статуса/прочтения своего сообщения — единый источник истины для
/// глифа, размера и цвета: часики (sending) → одиночная галочка (sent, outline)
/// → двойная галочка (read, primary). Golden-страж `ledger:RL-receipts-indicators`
/// рендерит РЕАЛЬНЫЙ виджет (не копию): правка иконки/размера/маппинга цвета
/// здесь детерминированно роняет golden. Цвет по умолчанию берётся из
/// `colorScheme` (тема); [color] позволяет переопределить (белый на overlay-
/// плашке поверх медиа), не трогая themed-путь эталона.
class MessageReadIndicator extends StatelessWidget {
  final bool isSending;
  final bool isRead;
  final Color? color;
  const MessageReadIndicator({
    required this.isSending,
    required this.isRead,
    this.color,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (isSending) {
      return Icon(
        Icons.access_time_rounded,
        size: 14,
        color: color ?? theme.colorScheme.outline,
      );
    }
    return Icon(
      isRead ? Icons.done_all_rounded : Icons.done_rounded,
      size: 14,
      color:
          color ??
          (isRead ? theme.colorScheme.primary : theme.colorScheme.outline),
    );
  }
}
