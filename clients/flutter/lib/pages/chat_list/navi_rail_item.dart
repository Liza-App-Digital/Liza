import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:badges/badges.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/widgets/hover_builder.dart';
import 'package:liza/widgets/unread_rooms_badge.dart';
import '../../config/themes.dart';

// Пояснение с подписью (макет «Создать компанию») — тёмной карточкой СПРАВА от
// кнопки: штатный тултип встаёт над/под пунктом и перекрывает соседей по rail.
Offset _tooltipRightOfTarget(TooltipPositionContext c) {
  const gap = 12.0;
  final top = c.target.dy - c.targetSize.height / 2;
  final maxTop = math.max(0.0, c.overlaySize.height - c.tooltipSize.height);
  return Offset(
    c.target.dx + c.targetSize.width / 2 + gap,
    top.clamp(0.0, maxTop),
  );
}

class NaviRailItem extends StatelessWidget {
  final String toolTip;

  /// Вторая строка тултипа — пояснение под жирным заголовком [toolTip].
  final String? toolTipSubtitle;
  final bool isSelected;
  final void Function() onTap;
  final Widget icon;
  final Widget? selectedIcon;
  final String badgeScope;
  final String? badgeScopeRoomId;
  final bool Function(Room)? unreadBadgeFilter;

  const NaviRailItem({
    required this.toolTip,
    this.toolTipSubtitle,
    required this.isSelected,
    required this.onTap,
    required this.icon,
    this.selectedIcon,
    this.badgeScope = 'filtered',
    this.badgeScopeRoomId,
    this.unreadBadgeFilter,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final borderRadius = BorderRadius.circular(AppConfig.borderRadius);
    final icon = isSelected ? selectedIcon ?? this.icon : this.icon;
    final unreadBadgeFilter = this.unreadBadgeFilter;
    final toolTipSubtitle = this.toolTipSubtitle;
    final tooltipStyle =
        theme.tooltipTheme.textStyle ??
        theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onInverseSurface,
        );
    return HoverBuilder(
      builder: (context, hovered) {
        return SizedBox(
          height: 72,
          width: LizaThemes.navRailWidth,
          child: Stack(
            children: [
              Positioned(
                top: 8,
                bottom: 8,
                left: 0,
                child: AnimatedContainer(
                  width: isSelected
                      ? LizaThemes.isColumnMode(context)
                            ? 8
                            : 4
                      : 0,
                  duration: LizaThemes.animationDuration,
                  curve: LizaThemes.animationCurve,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(90),
                      bottomRight: Radius.circular(90),
                    ),
                  ),
                ),
              ),
              Center(
                child: AnimatedScale(
                  scale: hovered ? 1.1 : 1.0,
                  duration: LizaThemes.animationDuration,
                  curve: LizaThemes.animationCurve,
                  child: Material(
                    borderRadius: borderRadius,
                    color: isSelected
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHigh,
                    child: Tooltip(
                      positionDelegate: toolTipSubtitle == null
                          ? null
                          : _tooltipRightOfTarget,
                      padding: toolTipSubtitle == null
                          ? null
                          : const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                      decoration: toolTipSubtitle == null
                          ? null
                          : BoxDecoration(
                              color: theme.colorScheme.inverseSurface,
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x38000000),
                                  blurRadius: 24,
                                  offset: Offset(0, 10),
                                ),
                              ],
                            ),
                      // richMessage с WidgetSpan отдаёт в семантику U+FFFC вместо
                      // текста — имя кнопки задаёт Semantics ниже.
                      excludeFromSemantics: true,
                      // Имя компании приходит из room state и длину не
                      // ограничено ничем на сервере: сырой `message:` рисовал
                      // плашку на пол-экрана (LABA-2536). `richMessage` даёт
                      // ConstrainedBox, но, в отличие от `message:`, НЕ
                      // наследует стиль темы — задаём его явно, иначе
                      // короткие тултипы теряют контраст.
                      richMessage: WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 240),
                          // Один Text и с пояснением: стражи LABA-2536 меряют
                          // ширину и цвет последнего Text тултипа.
                          child: toolTipSubtitle == null
                              ? Text(
                                  toolTip,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: tooltipStyle,
                                )
                              : Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: toolTip,
                                        style: theme.textTheme.bodyLarge
                                            ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                              color: theme
                                                  .colorScheme
                                                  .onInverseSurface,
                                            ),
                                      ),
                                      TextSpan(
                                        text: '\n$toolTipSubtitle',
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              height: 1.35,
                                              color: theme
                                                  .colorScheme
                                                  .onInverseSurface
                                                  .withValues(alpha: 0.8),
                                            ),
                                      ),
                                    ],
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: tooltipStyle,
                                ),
                        ),
                      ),
                      child: Semantics(
                        button: true,
                        label: toolTipSubtitle == null
                            ? toolTip
                            : '$toolTip. $toolTipSubtitle',
                        child: InkWell(
                          borderRadius: borderRadius,
                          onTap: onTap,
                          child: unreadBadgeFilter == null
                              ? icon
                              : UnreadRoomsBadge(
                                  scope: badgeScope,
                                  scopeRoomId: badgeScopeRoomId,
                                  filter: unreadBadgeFilter,
                                  badgePosition: BadgePosition.topEnd(
                                    top: -12,
                                    end: -8,
                                  ),
                                  child: icon,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
