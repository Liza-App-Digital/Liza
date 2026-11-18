import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/sticker_picker_dialog.dart';
import 'package:liza/utils/emoji_history_store.dart';
import 'package:liza/widgets/liza_emoji_picker.dart';
import 'chat.dart';

class ChatEmojiPicker extends StatelessWidget {
  final ChatController controller;
  const ChatEmojiPicker(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    // Размер анимируется снаружи: содержимое сразу получает конечную высоту.
    // Иначе первые кадры открытия сжимают TabBar + поиск до нескольких пикселей.
    return AnimatedSize(
      duration: LizaThemes.animationDuration,
      curve: LizaThemes.animationCurve,
      clipBehavior: Clip.hardEdge,
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: controller.showEmojiPicker
            ? MediaQuery.sizeOf(context).height / 2
            : 0,
        child: controller.showEmojiPicker
            ? DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    TabBar(
                      tabs: [
                        Tab(text: L10n.of(context).emojis),
                        Tab(text: L10n.of(context).stickers),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          LizaEmojiPicker(
                            key: ValueKey(controller.room.client.userID),
                            history: controller.emojiHistoryFor(
                              EmojiUsage.text,
                            ),
                            onEmojiSelected: controller.onEmojiSelected,
                            onBackspacePressed: controller.emojiPickerBackspace,
                          ),
                          StickerPickerDialog(
                            room: controller.room,
                            onSelected: (sticker) {
                              controller.room.sendEvent(
                                {
                                  'body': sticker.body,
                                  'info': sticker.info ?? {},
                                  'url': sticker.url.toString(),
                                },
                                type: EventTypes.Sticker,
                                threadRootEventId: controller.activeThreadId,
                                threadLastEventId: controller.threadLastEventId,
                              );
                              controller.hideEmojiPicker();
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            : null,
      ),
    );
  }
}
