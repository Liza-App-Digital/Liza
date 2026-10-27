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

  // Фон буквенного аватара без картинки — пастель чатов-запросов Лизы
  // (`PALETTE` в servers/bots/liza/request_avatar.py), по хэшу имени, буква
  // #1A1A1A. Надежда 26.10: «сделай аватарки обратно цветными, как было»
  // + Роман: «не такая ляпистая палитра, а ближе к аватаркам, которые для
  // Лизы сейчас генерятся». Один набор на обе темы — как PNG запросов, которые
  // тоже не перекрашиваются тёмной темой. Константы, не токены темы: seed темы
  // берётся из системы (Material You, акцент macOS).
  // Спека: docs/superpowers/specs/2026-10-26-avatar-pastel-colors-design.md
  // ledger:RL-avatar-unified-style
  static const List<Color> fallbackBackgrounds = [
    Color(0xFFEEF5B8),
    Color(0xFFCDE8C0),
    Color(0xFFC4D6F2),
    Color(0xFFDCCBEA),
    Color(0xFFF6D5BF),
  ];
  static const Color fallbackLetter = Color(0xFF1A1A1A);

  static int fallbackShade(String? name) {
    if (name == null) return 0;
    var sum = 0;
    for (final unit in name.codeUnits) {
      sum += unit;
    }
    return sum % fallbackBackgrounds.length;
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

    final fallbackBackground =
        backgroundColor ?? fallbackBackgrounds[fallbackShade(name)];
    // Явный фон вызывающего рассчитан на белую букву (space_view, панели).
    final fallbackText =
        textColor ?? (backgroundColor != null ? Colors.white : fallbackLetter);

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
