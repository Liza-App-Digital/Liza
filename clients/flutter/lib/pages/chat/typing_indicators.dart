import 'dart:async';

import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/widget_generating_card.dart';
import 'package:liza/utils/widget_progress.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart';

class TypingIndicators extends StatelessWidget {
  final ChatController controller;
  const TypingIndicators(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final store = WidgetProgressStore.of(controller.room.client);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final progress = store.forRoom(controller.room.id);
        if (progress == null || !progress.active) return _buildTyping(context);
        final member = controller.room.getState(
          EventTypes.RoomMember,
          progress.senderId,
        );
        final avatar = member?.content.tryGet<String>('avatar_url');
        final name =
            member?.content.tryGet<String>('displayname') ?? progress.senderId;
        return WidgetGeneratingRow(
          avatarUrl: avatar != null ? Uri.tryParse(avatar) : null,
          name: name,
          isAi: Matrix.of(context).isAiUser(progress.senderId),
          progress: progress,
        );
      },
    );
  }

  Widget _buildTyping(BuildContext context) {
    final theme = Theme.of(context);

    const avatarSize = Avatar.defaultSize / 2;

    return StreamBuilder<Object>(
      stream: controller.room.client.onSync.stream.where(
        (syncUpdate) =>
            syncUpdate.rooms?.join?[controller.room.id]?.ephemeral?.any(
              (ephemeral) => ephemeral.type == 'm.typing',
            ) ??
            false,
      ),
      builder: (context, _) {
        final typingUsers = controller.room.typingUsers
          ..removeWhere((u) => u.stateKey == Matrix.of(context).client.userID);

        return Container(
          width: double.infinity,
          alignment: Alignment.center,
          child: AnimatedContainer(
            constraints: const BoxConstraints(
              maxWidth: LizaThemes.maxTimelineWidth,
            ),
            height: typingUsers.isEmpty ? 0 : avatarSize + 8,
            duration: LizaThemes.animationDuration,
            curve: LizaThemes.animationCurve,
            alignment:
                controller.timeline!.events.isNotEmpty &&
                    controller.timeline!.events.first.senderId ==
                        Matrix.of(context).client.userID
                ? Alignment.topRight
                : Alignment.topLeft,
            clipBehavior: Clip.hardEdge,
            decoration: const BoxDecoration(),
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Row(
              children: [
                Container(
                  alignment: Alignment.center,
                  height: avatarSize,
                  width: Avatar.defaultSize,
                  child: Stack(
                    children: [
                      if (typingUsers.isNotEmpty)
                        Avatar(
                          size: avatarSize,
                          mxContent: typingUsers.first.avatarUrl,
                          name: typingUsers.first.calcDisplayname(),
                          isHexagonal: Matrix.of(
                            context,
                          ).isAiUser(typingUsers.first.id),
                        ),
                      if (typingUsers.length == 2)
                        Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: Avatar(
                            size: avatarSize,
                            mxContent: typingUsers.length == 2
                                ? typingUsers.last.avatarUrl
                                : null,
                            name: typingUsers.length == 2
                                ? typingUsers.last.calcDisplayname()
                                : '+${typingUsers.length - 1}',
                            isHexagonal:
                                typingUsers.length == 2 &&
                                Matrix.of(
                                  context,
                                ).isAiUser(typingUsers.last.id),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: const BorderRadius.all(
                    Radius.circular(AppConfig.borderRadius),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: typingUsers.isEmpty ? null : const _TypingDots(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => __TypingDotsState();
}

class __TypingDotsState extends State<_TypingDots> {
  int _tick = 0;

  late final Timer _timer;

  static const Duration animationDuration = Duration(milliseconds: 300);

  @override
  void initState() {
    _timer = Timer.periodic(animationDuration, (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _tick = (_tick + 1) % 4;
      });
    });
    super.initState();
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const size = 8.0;

    return Row(
      mainAxisSize: .min,
      children: [
        for (var i = 1; i <= 3; i++)
          AnimatedContainer(
            duration: animationDuration * 1.5,
            curve: LizaThemes.animationCurve,
            width: size,
            height: _tick == i ? size * 2 : size,
            margin: EdgeInsets.symmetric(
              horizontal: 2,
              vertical: _tick == i ? 4 : 8,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * 2),
              color: theme.colorScheme.secondary,
            ),
          ),
      ],
    );
  }
}
