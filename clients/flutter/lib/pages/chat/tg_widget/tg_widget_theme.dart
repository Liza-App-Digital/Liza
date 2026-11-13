import 'package:flutter/material.dart';

import 'package:liza/config/themes.dart';

/// Тема виджета в терминах профиля 1. `bg_color` — цвет пузыря, в котором
/// виджет стоит: входящего для сообщения бота, исходящего для своего.
class TgWidgetTheme {
  final String colorScheme;
  final Map<String, String> themeParams;
  final double fontSize;

  const TgWidgetTheme({
    required this.colorScheme,
    required this.themeParams,
    required this.fontSize,
  });

  static String hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

  factory TgWidgetTheme.of(
    ThemeData theme, {
    required bool outgoing,
    required double fontSize,
  }) {
    final cs = theme.colorScheme;
    final bg = outgoing ? theme.bubbleColor : cs.surfaceContainerHigh;
    final text = outgoing ? theme.onBubbleColor : cs.onSurface;
    final hint = text.withAlpha(140);
    final link = outgoing
        ? (theme.brightness == Brightness.light
              ? cs.primaryFixed
              : cs.onTertiaryContainer)
        : cs.primary;
    return TgWidgetTheme(
      colorScheme: theme.brightness == Brightness.dark ? 'dark' : 'light',
      fontSize: fontSize,
      themeParams: {
        'bg_color': hex(bg),
        'text_color': hex(text),
        'hint_color': hex(hint),
        'link_color': hex(link),
        'button_color': hex(cs.primary),
        'button_text_color': hex(cs.onPrimary),
        'secondary_bg_color': hex(cs.surfaceContainerHighest),
        'accent_text_color': hex(link),
        'subtitle_text_color': hex(hint),
        'destructive_text_color': hex(cs.error),
        'section_bg_color': hex(bg),
        'section_header_text_color': hex(link),
        'section_separator_color': hex(cs.outlineVariant),
        'header_bg_color': hex(bg),
        'bottom_bar_bg_color': hex(bg),
      },
    );
  }

  /// CSS-переменные на `:root` (шим ставит их `!important`).
  Map<String, String> get cssVars => {
    for (final e in themeParams.entries)
      '--tg-theme-${e.key.replaceAll('_', '-')}': e.value,
    '--tg-color-scheme': colorScheme,
    '--tg-text-font-size': '${fontSize.toStringAsFixed(0)}px',
    '--tg-text-line-height': '1.35',
    '--tg-text-padding': '8px 12px',
    '--tg-button-bg': themeParams['button_color']!,
    '--tg-button-text': themeParams['button_text_color']!,
    '--tg-button-radius': '10px',
    '--tg-button-font': '500 ${fontSize.toStringAsFixed(0)}px system-ui',
    '--tg-button-padding': '0 16px',
    '--tg-button-height': '36px',
    '--tg-button-pressed-opacity': '0.7',
    '--tg-button-disabled-opacity': '0.4',
  };

  bool sameAs(TgWidgetTheme other) =>
      colorScheme == other.colorScheme &&
      fontSize == other.fontSize &&
      themeParams.length == other.themeParams.length &&
      themeParams.entries.every((e) => other.themeParams[e.key] == e.value);
}

/// Зона под временем сообщения (`contentSafeAreaInset`). Время накрывает низ
/// виджета только когда подписи нет — иначе оно стоит под подписью.
class TgWidgetInset {
  final double bottom;
  final double cornerRight;

  const TgWidgetInset({this.bottom = 0, this.cornerRight = 0});

  Map<String, Object> toJson() => {
    'top': 0,
    'right': 0,
    'bottom': bottom.round(),
    'left': 0,
    'cornerRight': cornerRight.round(),
    'cornerLeft': 0,
  };

  Map<String, String> get cssVars => {
    '--tg-content-safe-area-inset-top': '0px',
    '--tg-content-safe-area-inset-right': '0px',
    '--tg-content-safe-area-inset-bottom': '${bottom.round()}px',
    '--tg-content-safe-area-inset-left': '0px',
    '--tg-content-safe-area-corner-left': '0px',
    '--tg-content-safe-area-corner-right': '${cornerRight.round()}px',
  };

  @override
  bool operator ==(Object other) =>
      other is TgWidgetInset &&
      other.bottom == bottom &&
      other.cornerRight == cornerRight;

  @override
  int get hashCode => Object.hash(bottom, cornerRight);
}
