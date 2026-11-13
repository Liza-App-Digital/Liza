import 'package:flutter/material.dart';

import 'package:liza/widgets/hexagon_clipper.dart';

enum StoryRingState { none, seen, unseen }

/// Оборачивает аватарку градиентным кольцом сторисов.
/// none - кольца нет; seen - тусклое серое; unseen - яркий градиент.
///
/// Кольцо рисуется ВНУТРИ заданного [size] (аватарка ужимается на толщину
/// кольца + зазор), поэтому общий бокс остаётся ровно [size] и не вылезает
/// за пределы родительского контейнера (иначе кольцо обрезалось в списке
/// чатов, где аватарка лежит в SizedBox фиксированного размера).
///
/// [hexagonal] - кольцо повторяет шестиугольник аватарки бота (роль ai):
/// круглое кольцо вокруг соты читалось как рассинхрон формы (Роман 13.11).
class StoryAvatarRing extends StatelessWidget {
  const StoryAvatarRing({
    required this.state,
    required this.child,
    this.size = 56,
    this.hexagonal = false,
    super.key,
  });

  final StoryRingState state;
  final Widget child;
  final double size;
  final bool hexagonal;

  // Тонкое кольцо: жирное визуально перегружало мелкие аватарки в списках.
  static const double ringWidth = 1.5;
  static const double gap = 1.5;

  @override
  Widget build(BuildContext context) {
    if (state == StoryRingState.none) {
      return SizedBox(width: size, height: size, child: child);
    }
    final theme = Theme.of(context);
    final gradient = state == StoryRingState.unseen
        ? const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFE0080), Color(0xFFFF8C00), Color(0xFFFFD600)],
          )
        : LinearGradient(
            colors: [
              theme.colorScheme.outlineVariant,
              theme.colorScheme.outlineVariant,
            ],
          );
    final ShapeBorder shape = hexagonal
        ? const HexagonBorder()
        : const CircleBorder();
    return SizedBox(
      width: size,
      height: size,
      child: Container(
        padding: const EdgeInsets.all(ringWidth),
        decoration: ShapeDecoration(shape: shape, gradient: gradient),
        child: Container(
          decoration: ShapeDecoration(
            shape: shape,
            color: theme.colorScheme.surface,
          ),
          padding: const EdgeInsets.all(gap),
          child: hexagonal
              ? ClipPath(clipper: HexagonClipper(), child: child)
              : ClipOval(child: child),
        ),
      ),
    );
  }
}
