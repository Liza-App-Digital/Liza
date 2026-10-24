import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/widgets/hexagon_clipper.dart';
import 'package:liza/widgets/mxc_image.dart';
// ignore: unused_import
import 'package:liza/widgets/presence_builder.dart';
import 'package:liza/widgets/story_avatar_ring.dart';

class Avatar extends StatelessWidget {
  final Uri? mxContent;
  final String? name;
  final double size;
  final void Function()? onTap;
  static const double defaultSize = 44;
  final Client? client;
  final String? presenceUserId;
  final Color? presenceBackgroundColor;
  final BorderRadius? borderRadius;
  final IconData? icon;
  final BorderSide? border;
  final Color? backgroundColor;
  final Color? textColor;
  final bool isHexagonal;

  /// Аватар удалённого аккаунта (LABA-2242): серый круг + иконка-призрак вместо
  /// картинки/буквы. Игнорирует [mxContent] — у деактивированного бота аватар
  /// может ещё кэшироваться, но визуально аккаунт должен читаться как удалённый.
  final bool isDeleted;
  final StoryRingState? storyRing;

  /// Колбэк тапа, когда у аватарки активное кольцо (есть сторис). Имеет
  /// приоритет над [onTap]: тап по кружку открывает сторис-просмотрщик.
  final void Function()? onStoryTap;

  // Фон буквенного аватара без картинки — нейтральные серые, по одному из трёх
  // на имя (Надежда 23.10: «для людей сделаем фон не цветной … оттенков серого
  // в стиле интерфейса»; цветные — только пастельные ИИ-запросы). Константы, а
  // не токены темы: seed темы берётся из системы (Material You, акцент macOS),
  // и «серые» на разных устройствах окрасились бы по-разному. Буква — тёмная
  // на светлом / светлая на тёмном, контраст ≥ 5.4.
  // Спека: docs/superpowers/specs/2026-10-23-avatar-unified-style-design.md
  // ledger:RL-avatar-unified-style
  static const List<Color> lightFallbackBackgrounds = [
    Color(0xFFE3E5E8),
    Color(0xFFD6D9DE),
    Color(0xFFC9CDD3),
  ];
  static const List<Color> darkFallbackBackgrounds = [
    Color(0xFF3C4043),
    Color(0xFF4A4E54),
    Color(0xFF5A5E66),
  ];
  static const Color lightFallbackLetter = Color(0xFF3C4043);
  static const Color darkFallbackLetter = Color(0xFFE8EAED);

  static int fallbackShade(String? name) {
    if (name == null) return 0;
    var sum = 0;
    for (final unit in name.codeUnits) {
      sum += unit;
    }
    return sum % lightFallbackBackgrounds.length;
  }

  const Avatar({
    this.mxContent,
    this.name,
    this.size = defaultSize,
    this.onTap,
    this.client,
    this.presenceUserId,
    this.presenceBackgroundColor,
    this.borderRadius,
    this.border,
    this.icon,
    this.backgroundColor,
    this.textColor,
    this.isHexagonal = false,
    this.isDeleted = false,
    this.storyRing,
    this.onStoryTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final name = this.name;
    final fallbackLetters = name == null || name.isEmpty
        ? '@'
        : name.substring(0, 1);

    final isDark = theme.brightness == Brightness.dark;
    final fallbackBackground =
        backgroundColor ??
        (isDark
            ? darkFallbackBackgrounds
            : lightFallbackBackgrounds)[fallbackShade(name)];
    // Явный фон вызывающего рассчитан на белую букву (space_view, панели).
    final fallbackText =
        textColor ??
        (backgroundColor != null
            ? Colors.white
            : isDark
            ? darkFallbackLetter
            : lightFallbackLetter);

    final noPic =
        mxContent == null ||
        mxContent.toString().isEmpty ||
        mxContent.toString() == 'null';
    // При активном кольце аватарка ужимается на толщину кольца + зазор, чтобы
    // общий бокс остался ровно [size] и кольцо не вылезло за пределы родителя
    // (иначе обрезалось в списке чатов). Без кольца innerSize == size.
    final hasRing = storyRing != null && storyRing != StoryRingState.none;
    final innerSize = hasRing
        ? size - 2 * (StoryAvatarRing.ringWidth + StoryAvatarRing.gap)
        : size;
    final borderRadius =
        this.borderRadius ?? BorderRadius.circular(innerSize / 2);
    // final presenceUserId = this.presenceUserId; // используется в закомментированном presence-блоке

    final ShapeBorder shape = isHexagonal
        ? HexagonBorder(side: border ?? BorderSide.none)
        : RoundedRectangleBorder(
            borderRadius: borderRadius,
            side: border ?? BorderSide.none,
          );

    final container = Stack(
      children: [
        SizedBox(
          width: innerSize,
          height: innerSize,
          child: Material(
            color: theme.brightness == Brightness.light
                ? Colors.white
                : Colors.black,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: isDeleted
                ? Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.person_off_outlined,
                      color: theme.colorScheme.outline,
                      size: innerSize / 1.7,
                    ),
                  )
                : MxcImage(
                    client: client,
                    borderRadius: isHexagonal
                        ? BorderRadius.zero
                        : borderRadius,
                    key: ValueKey(mxContent.toString()),
                    cacheKey: '${mxContent}_$innerSize',
                    uri: mxContent,
                    fit: BoxFit.cover,
                    width: innerSize,
                    height: innerSize,
                    placeholder: (_) => noPic
                        ? Container(
                            decoration: BoxDecoration(
                              color: fallbackBackground,
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              fallbackLetters,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: 'RobotoMono',
                                color: fallbackText,
                                fontWeight: FontWeight.bold,
                                fontSize: (innerSize / 2.5).roundToDouble(),
                              ),
                            ),
                          )
                        : Center(
                            child: Icon(
                              Icons.person_2,
                              color: theme.colorScheme.tertiary,
                              size: innerSize / 1.5,
                            ),
                          ),
                  ),
          ),
        ),
        // Presence-индикаторы временно отключены по решению пользователя (см. ветку stories-fixes). Код сохранён для возврата.
        // if (presenceUserId != null)
        //   PresenceBuilder(
        //     client: client,
        //     userId: presenceUserId,
        //     builder: (context, presence) {
        //       if (presence == null ||
        //           (presence.presence == PresenceType.offline &&
        //               presence.lastActiveTimestamp == null)) {
        //         return const SizedBox.shrink();
        //       }
        //       final dotColor = presence.presence.isOnline
        //           ? Colors.green
        //           : presence.presence.isUnavailable
        //           ? Colors.orange
        //           : Colors.grey;
        //       return Positioned(
        //         bottom: -3,
        //         right: -3,
        //         child: Container(
        //           width: 16,
        //           height: 16,
        //           decoration: BoxDecoration(
        //             color: presenceBackgroundColor ?? theme.colorScheme.surface,
        //             borderRadius: BorderRadius.circular(32),
        //           ),
        //           alignment: Alignment.center,
        //           child: Container(
        //             width: 10,
        //             height: 10,
        //             decoration: BoxDecoration(
        //               color: dotColor,
        //               borderRadius: BorderRadius.circular(16),
        //               border: Border.all(
        //                 width: 1,
        //                 color: theme.colorScheme.surface,
        //               ),
        //             ),
        //           ),
        //         ),
        //       );
        //     },
        //   ),
      ],
    );
    final ringed = hasRing
        ? StoryAvatarRing(state: storyRing!, size: size, child: container)
        : container;
    // При активном кольце тап ведёт в сторис-просмотрщик (onStoryTap), иначе -
    // обычный onTap (картинка-аватар / профиль / чат).
    final effectiveTap = hasRing && onStoryTap != null ? onStoryTap : onTap;
    if (effectiveTap == null) return ringed;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: effectiveTap, child: ringed),
    );
  }
}
