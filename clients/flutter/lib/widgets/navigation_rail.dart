import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/navi_rail_item.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/utils/stream_extension.dart';
import 'package:liza/utils/support_chat.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart';

class SpacesNavigationRail extends StatelessWidget {
  final String? activeSpaceId;
  final void Function() onGoToChats;
  final void Function(String) onGoToSpaceId;

  const SpacesNavigationRail({
    required this.activeSpaceId,
    required this.onGoToChats,
    required this.onGoToSpaceId,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final isSettings = GoRouter.of(
      context,
    ).routeInformationProvider.value.uri.path.startsWith('/rooms/settings');
    return Material(
      child: SafeArea(
        bottom: false,
        child: StreamBuilder(
          key: ValueKey(client.userID.toString()),
          stream: client.onSync.stream
              .where((s) => s.hasRoomUpdate)
              .rateLimit(const Duration(seconds: 1)),
          builder: (context, _) {
            final allSpaces = client.rooms
                .where((room) => room.isSpace)
                .toList();

            final singleSpaceService = Matrix.of(context).singleSpaceService;
            return FutureBuilder(
              future: singleSpaceService.fetch(),
              builder: (context, snapshot) {
                // Пока ответа нет — "+" не рисуем, чтобы вместо одного не мелькал
                // другой. Кэш fetch() отдаёт ответ синхронно, если флаг уже известен.
                // «Новое пространство» — только когда сервер ПОДТВЕРДИЛ, что главное
                // пространство создать можно: ответ 200 «его нет» или модуля
                // single_space_guard нет вовсе (локальный стенд). fetch() на сбой
                // сети тоже отдаёт exists:false, и прод-юзер получил бы 403.
                final canCreateRootSpace =
                    snapshot.hasData &&
                    (singleSpaceService.knownNotToExist ||
                        singleSpaceService.guardDisabled);
                // «Создать компанию» (→ поддержка) — везде, где отсутствие главного
                // пространства не подтверждено; без модуля — рядом с «Новое пространство».
                final canAskSupport =
                    snapshot.hasData && !singleSpaceService.knownNotToExist;
                final addButtonSlots =
                    (canCreateRootSpace ? 1 : 0) + (canAskSupport ? 1 : 0);

                return SizedBox(
                  width: LizaThemes.isColumnMode(context)
                      ? LizaThemes.navRailWidth
                      : LizaThemes.navRailWidth * 0.75,
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView.builder(
                          scrollDirection: Axis.vertical,
                          itemCount: allSpaces.length + 1 + addButtonSlots,
                          itemBuilder: (context, i) {
                            if (i == 0) {
                              return NaviRailItem(
                                isSelected:
                                    activeSpaceId == null && !isSettings,
                                onTap: onGoToChats,
                                icon: const Padding(
                                  padding: EdgeInsets.all(10.0),
                                  child: Icon(Icons.forum_outlined),
                                ),
                                selectedIcon: const Padding(
                                  padding: EdgeInsets.all(10.0),
                                  child: Icon(Icons.forum),
                                ),
                                toolTip: L10n.of(context).chats,
                                unreadBadgeFilter: (room) => true,
                              );
                            }
                            i--;
                            if (canCreateRootSpace && i == allSpaces.length) {
                              return NaviRailItem(
                                isSelected: false,
                                onTap: () => context.go('/rooms/newspace'),
                                icon: const Padding(
                                  padding: EdgeInsets.all(8.0),
                                  child: Icon(Icons.add),
                                ),
                                toolTip: L10n.of(context).createNewSpace,
                              );
                            }
                            if (canAskSupport && i >= allSpaces.length) {
                              return NaviRailItem(
                                key: const ValueKey('rail_create_company'),
                                isSelected: false,
                                onTap: () =>
                                    confirmCreateCompanyRequest(context),
                                icon: const _CreateCompanyRailIcon(),
                                toolTip: L10n.of(
                                  context,
                                ).createCompanyViaSupport,
                                toolTipSubtitle: L10n.of(
                                  context,
                                ).createCompanyRailHint,
                              );
                            }
                            final space = allSpaces[i];
                            final displayname = allSpaces[i]
                                .getLocalizedDisplayname(
                                  MatrixLocals(L10n.of(context)),
                                );
                            final spaceChildrenIds = space.spaceChildren
                                .map((c) => c.roomId)
                                .toSet();
                            return NaviRailItem(
                              toolTip: displayname,
                              isSelected: activeSpaceId == space.id,
                              onTap: () => onGoToSpaceId(allSpaces[i].id),
                              unreadBadgeFilter: (room) =>
                                  spaceChildrenIds.contains(room.id),
                              icon: Avatar(
                                mxContent: allSpaces[i].avatar,
                                name: displayname,
                                border: BorderSide(
                                  width: 1,
                                  color: Theme.of(context).dividerColor,
                                ),
                                borderRadius: BorderRadius.circular(
                                  AppConfig.borderRadius / 2,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      NaviRailItem(
                        isSelected: isSettings,
                        onTap: () => context.go('/rooms/settings'),
                        icon: const Padding(
                          padding: EdgeInsets.all(10.0),
                          child: Icon(Icons.settings_outlined),
                        ),
                        selectedIcon: const Padding(
                          padding: EdgeInsets.all(10.0),
                          child: Icon(Icons.settings),
                        ),
                        toolTip: L10n.of(context).settings,
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// «+» «Создать компанию» по макету: квадрат со скруглением как у аватаров компаний
/// на rail, светлая подложка и пунктир; при наведении — акцентные рамка и «+».
class _CreateCompanyRailIcon extends StatefulWidget {
  const _CreateCompanyRailIcon();

  @override
  State<_CreateCompanyRailIcon> createState() => _CreateCompanyRailIconState();
}

class _CreateCompanyRailIconState extends State<_CreateCompanyRailIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = AppConfig.borderRadius / 2;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox.square(
        key: const ValueKey('rail_create_company_icon'),
        dimension: Avatar.defaultSize,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _hovered
                ? scheme.primaryContainer.withValues(alpha: 0.4)
                : scheme.surface,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: CustomPaint(
            painter: _DashedBorderPainter(
              color: _hovered ? scheme.primary : scheme.outlineVariant,
              radius: radius,
            ),
            child: Icon(
              Icons.add,
              color: _hovered ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Пунктирная рамка «+» «Создать компанию» — отличает кнопку от аватаров компаний.
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const _dash = 4.0;
  static const _gap = 3.0;
  static const _strokeWidth = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(_strokeWidth / 2),
          Radius.circular(radius),
        ),
      );
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += _dash + _gap) {
        canvas.drawPath(metric.extractPath(d, d + _dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
