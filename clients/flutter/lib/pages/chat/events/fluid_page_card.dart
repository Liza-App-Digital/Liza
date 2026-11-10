import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/utils/fluid_page.dart';
import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:liza/utils/platform_infos.dart';

/// Запас на расхождение часов клиента и сервера: страница, пришедшая сразу
/// после открытия чата, не должна отсечься из-за отстающих часов сервера.
const Duration kFluidPageClockSkew = Duration(seconds: 10);

/// Решение «открыть страницу сама» для события живого sync (зовёт контроллер
/// чата, а не карточка: карточка под длинным ответом за экраном не строится).
/// Только этот чат, только страница от бота, пришедшая после открытия чата,
/// только в режиме панели сбоку и ровно один раз на eventId. История и
/// мобильный лист — тапом по карточке.
bool shouldAutoOpenLiveFluidPage({
  required Event event,
  required String roomId,
  required DateTime openedAt,
  required bool sideLayout,
  required bool Function(String userId) isBotOrAiUser,
}) {
  if (!sideLayout || event.roomId != roomId) return false;
  if (!isFluidPageEvent(event)) return false;
  if (!isFluidPageSender(event, isBotOrAiUser: isBotOrAiUser)) return false;
  if (event.originServerTs.isBefore(openedAt.subtract(kFluidPageClockSkew))) {
    return false;
  }
  // Панель «собираю» закрыли — значит, страница этого обещания не нужна сама.
  final pendingOf = fluidPagePendingOf(event);
  if (pendingOf != null &&
      MiniAppManager.instance.isPendingDismissed(pendingOf)) {
    return false;
  }
  return MiniAppManager.instance.claimAutoOpen(event.eventId);
}

/// Обещание страницы или его этап от бота этого чата, пришедшие живым sync;
/// иначе null. История (до открытия чата) не считается.
FluidPagePending? liveFluidPagePending({
  required Event event,
  required String roomId,
  required DateTime openedAt,
  required bool Function(String userId) isBotOrAiUser,
}) {
  if (event.roomId != roomId) return null;
  if (event.senderId == event.room.client.userID ||
      !isBotOrAiUser(event.senderId)) {
    return null;
  }
  if (event.originServerTs.isBefore(openedAt.subtract(kFluidPageClockSkew))) {
    return null;
  }
  return fluidPagePending(event);
}

/// Обещание пришло живым sync: на широком окне сразу открыть панель «собираю»
/// (ровно один раз на обещание), этапы — только обновляют уже открытую.
void applyLiveFluidPagePending(
  FluidPagePending pending, {
  required Event event,
  required bool sideLayout,
  required String title,
}) {
  final manager = MiniAppManager.instance;
  final isPromise = pending.id == event.eventId;
  if (isPromise &&
      !pending.finished &&
      sideLayout &&
      manager.claimAutoOpen(MiniAppManager.pendingUrl(pending.id))) {
    manager.openPendingPage(event.room, pending, title: title);
    return;
  }
  manager.updatePending(pending);
}

/// Карточка HTML-страницы в ленте чата. Тап — открыть страницу справа
/// (на мобильном — листом). Сама страница в ленту не встраивается.
class FluidPageCard extends StatefulWidget {
  final Event event;
  final Color textColor;

  const FluidPageCard({
    required this.event,
    required this.textColor,
    super.key,
  });

  @override
  State<FluidPageCard> createState() => _FluidPageCardState();
}

class _FluidPageCardState extends State<FluidPageCard> {
  /// Linux и Web: встроенного WebView нет — карточка открывает файл как
  /// обычное вложение.
  bool get _canEmbed => !PlatformInfos.isLinux && !PlatformInfos.isWeb;

  String get _title {
    final title = fluidPageTitle(widget.event);
    return title.isEmpty ? L10n.of(context).fluidPageOpen : title;
  }

  void _open() {
    if (!_canEmbed) {
      widget.event.openFile(context);
      return;
    }
    MiniAppManager.instance.openPage(widget.event, title: _title);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('fluid-page-card'),
        borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
        onTap: _open,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  child: const Icon(Icons.web_asset_outlined),
                ),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: widget.textColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        L10n.of(context).fluidPageOpen,
                        style: TextStyle(
                          color: widget.textColor.withAlpha(170),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
