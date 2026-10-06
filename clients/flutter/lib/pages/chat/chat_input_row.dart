import 'package:flutter/material.dart';

import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/news_poll.dart';
import 'package:liza/config/app_config.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/bot_commands_menu_button.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/pages/chat/recording_input_row.dart';
import 'package:liza/pages/chat/recording_view_model.dart';
import 'package:liza/utils/bot_miniapp_registry.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/widgets/mini_app_composer_button.dart';
import 'package:liza/utils/other_party_can_receive.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart';
import '../../config/themes.dart';
import 'chat.dart';
import 'input_bar.dart';

class ChatInputRow extends StatelessWidget {
  final ChatController controller;

  const ChatInputRow(this.controller, {super.key});

  Future<void> _openMiniApp(BuildContext context, MiniAppLaunch launch) async {
    await MiniAppWebView.open(
      context: context,
      appUrl: launch.appUrl,
      appId: launch.appId,
      appName: launch.appName,
      room: controller.room,
      appType: launch.appType,
      appStartPath: launch.appStartPath,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    const height = 48.0;

    // LABA-2242: чат с удалённым ботом — переписка заблокирована (паритет с
    // Liza: удалённому аккаунту писать нельзя). Проверяем ДО
    // otherPartyCanReceiveMessages: бот-DM нешифрованы, и та проверка их не ловит.
    if (isDeletedBotDm(controller.room)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Text(
            L10n.of(context).deletedAccountCannotWrite,
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (!controller.room.otherPartyCanReceiveMessages) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Text(
            L10n.of(context).otherPartyNotLoggedIn,
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final selectedTextButtonStyle = TextButton.styleFrom(
      foregroundColor: theme.colorScheme.onTertiaryContainer,
    );

    return RecordingViewModel(
      builder: (context, recordingViewModel) {
        if (recordingViewModel.isRecording) {
          return RecordingInputRow(
            state: recordingViewModel,
            onSend: controller.onVoiceMessageSend,
          );
        }
        return Row(
          crossAxisAlignment: .end,
          mainAxisAlignment: .spaceBetween,
          children: controller.selectMode
              ? <Widget>[
                  if (controller.selectedEvents.every(
                    (event) => event.status == EventStatus.error,
                  ))
                    SizedBox(
                      height: height,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        onPressed: controller.deleteErrorEventsAction,
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.delete_forever_outlined),
                            Text(L10n.of(context).delete),
                          ],
                        ),
                      ),
                    )
                  else if (!controller.room.isContentProtected)
                    SizedBox(
                      height: height,
                      child: TextButton(
                        style: selectedTextButtonStyle,
                        onPressed: controller.forwardEventsAction,
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.keyboard_arrow_left_outlined),
                            Text(L10n.of(context).forward),
                          ],
                        ),
                      ),
                    ),
                  controller.selectedEvents.length == 1
                      ? controller.selectedEvents.first
                                .getDisplayEvent(controller.timeline!)
                                .status
                                .isSent
                            ? SizedBox(
                                height: height,
                                child: TextButton(
                                  style: selectedTextButtonStyle,
                                  onPressed: controller.replyAction,
                                  child: Row(
                                    children: <Widget>[
                                      Text(L10n.of(context).reply),
                                      const Icon(Icons.keyboard_arrow_right),
                                    ],
                                  ),
                                ),
                              )
                            : SizedBox(
                                height: height,
                                child: TextButton(
                                  style: selectedTextButtonStyle,
                                  onPressed: controller.sendAgainAction,
                                  child: Row(
                                    children: <Widget>[
                                      Text(L10n.of(context).tryToSendAgain),
                                      const SizedBox(width: 4),
                                      const Icon(Icons.send_outlined, size: 16),
                                    ],
                                  ),
                                ),
                              )
                      : const SizedBox.shrink(),
                ]
              : <Widget>[
                  if (miniAppLaunchForRoom(controller.room) case final launch?)
                    SizedBox(
                      height: height,
                      child: TextButton(
                        onPressed: () => _openMiniApp(context, launch),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        child: Text(L10n.of(context).chatInputOpen),
                      ),
                    ),
                  // Кнопка-меню BotFather: пока не набран текст, слева от поля
                  // ввода — «☰ Меню», по тапу шлём боту «/menu» → в диалог приходит
                  // стартовая карточка приветствия (LABA-2195, фидбек Дениса:
                  // «Меню» должно вызывать главное меню, а не окно-панель). Тот же
                  // паттерн, что у кнопки «Меню» службы поддержки ниже. Прячется,
                  // когда начали печатать (как сворачивается «плюс»).
                  if (controller.sendController.text.isEmpty &&
                      isBotFatherRoom(controller.room))
                    SizedBox(
                      height: height,
                      child: TextButton.icon(
                        onPressed: () => controller.room.sendTextEvent(
                          '/menu',
                          parseCommands: false,
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                          backgroundColor: theme.colorScheme.primary.withValues(
                            alpha: 0.12,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        icon: const Icon(Icons.menu, size: 20),
                        label: Text(L10n.of(context).chatInputMenu),
                      ),
                    ),
                  // Меню службы поддержки: в чате «Liza support hub» слева от поля
                  // ввода — «☰ Меню», по тапу шлём боту «/menu», он отвечает
                  // карточкой (Необработанные заявки / Мои задачи / Обработанные).
                  if (controller.sendController.text.isEmpty &&
                      isSupportHubRoom(controller.room))
                    SizedBox(
                      height: height,
                      child: TextButton.icon(
                        onPressed: () => controller.room.sendTextEvent(
                          '/menu',
                          parseCommands: false,
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                          backgroundColor: theme.colorScheme.primary.withValues(
                            alpha: 0.12,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        icon: const Icon(Icons.menu, size: 20),
                        label: Text(L10n.of(context).chatInputMenu),
                      ),
                    ),
                  // Меню команд бота (setMyCommands): в DM с ботом, у которого
                  // есть команды. У BotFather и службы поддержки своя «Меню».
                  if (controller.sendController.text.isEmpty &&
                      controller.room.directChatMatrixID != null &&
                      !isBotFatherRoom(controller.room) &&
                      !isSupportHubRoom(controller.room))
                    BotCommandsMenuButton(
                      room: controller.room,
                      controller: controller.sendController,
                      focusNode: controller.inputFocus,
                      onChanged: controller.onInputBarChanged,
                      height: height,
                    ),
                  // Кнопка «Миниапп» (как menu button бота в Liza): в DM с
                  // ботом, у которого закреплён mini App, слева от «+» показываем
                  // кнопку открытия приложения. Гейт: обычный DM (не BotFather,
                  // не комната-лаунчер — у той уже есть «Открыть» выше), текст
                  // ещё не набран. Наличие app у бота приезжает из реестра
                  // (/liza/mybots), поэтому оборачиваем в ValueListenableBuilder,
                  // чтобы кнопка появилась, когда карта подгрузится.
                  if (controller.sendController.text.isEmpty &&
                      controller.room.directChatMatrixID != null &&
                      !isBotFatherRoom(controller.room) &&
                      miniAppLaunchForRoom(controller.room) == null)
                    ValueListenableBuilder<int>(
                      valueListenable: BotMiniAppRegistry.instance.revision,
                      builder: (context, _, _) {
                        BotMiniAppRegistry.instance.ensureLoaded(
                          controller.room.client,
                        );
                        final launch = BotMiniAppRegistry.instance
                            .launchForRoom(controller.room);
                        // Владелец мог выключить кнопку в чате через BotFather.
                        if (launch == null || !launch.composerButtonEnabled) {
                          return const SizedBox.shrink();
                        }
                        return MiniAppComposerButton(
                          height: height,
                          label:
                              launch.composerButtonLabel ??
                              L10n.of(context).chatInputOpen,
                          onTap: () => _openMiniApp(context, launch),
                        );
                      },
                    ),
                  // Кнопка эмодзи — только на ПК/веб: на мобильных эмодзи даёт
                  // системная клавиатура, а на десктопе/вебе системного пикера
                  // нет (LABA, фидбек Нади). Открывает уже готовую панель
                  // ChatEmojiPicker через controller.emojiPickerAction. Кнопка
                  // статична (в отличие от «+»/mic) — не прячется при наборе
                  // текста, т.к. эмодзи добавляют В набираемое сообщение.
                  if (!PlatformInfos.isMobile)
                    Container(
                      height: height,
                      width: height,
                      alignment: Alignment.center,
                      child: IconButton(
                        tooltip: L10n.of(context).emojis,
                        color: theme.colorScheme.onPrimaryContainer,
                        icon: Icon(
                          controller.showEmojiPicker
                              ? Icons.keyboard_outlined
                              : Icons.emoji_emotions_outlined,
                        ),
                        onPressed: controller.emojiPickerAction,
                      ),
                    ),
                  AnimatedContainer(
                    duration: LizaThemes.animationDuration,
                    curve: LizaThemes.animationCurve,
                    width: controller.sendController.text.isNotEmpty
                        ? 0
                        : height,
                    height: height,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(),
                    clipBehavior: Clip.hardEdge,
                    child: PopupMenuButton<AddPopupMenuActions>(
                      useRootNavigator: true,
                      icon: const Icon(Icons.add_circle_outline),
                      iconColor: theme.colorScheme.onPrimaryContainer,
                      onSelected: controller.onAddPopupMenuButtonSelected,
                      itemBuilder: (BuildContext context) => [
                        PopupMenuItem(
                          value: AddPopupMenuActions.gallery,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.onPrimaryContainer,
                              foregroundColor:
                                  theme.colorScheme.primaryContainer,
                              child: const Icon(Icons.photo_library_outlined),
                            ),
                            title: Text(
                              PlatformInfos.isMobile
                                  ? L10n.of(context).gallery
                                  : L10n.of(context).choosePhotoOrVideo,
                            ),
                            contentPadding: const EdgeInsets.all(0),
                          ),
                        ),
                        if (PlatformInfos.isMobile)
                          PopupMenuItem(
                            value: AddPopupMenuActions.camera,
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.onPrimaryContainer,
                                foregroundColor:
                                    theme.colorScheme.primaryContainer,
                                child: const Icon(Icons.camera_alt_outlined),
                              ),
                              title: Text(L10n.of(context).camera),
                              contentPadding: const EdgeInsets.all(0),
                            ),
                          ),
                        PopupMenuItem(
                          value: AddPopupMenuActions.file,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.onPrimaryContainer,
                              foregroundColor:
                                  theme.colorScheme.primaryContainer,
                              child: const Icon(Icons.attachment_outlined),
                            ),
                            title: Text(L10n.of(context).sendFile),
                            contentPadding: const EdgeInsets.all(0),
                          ),
                        ),
                        if (PlatformInfos.isMobile)
                          PopupMenuItem(
                            value: AddPopupMenuActions.location,
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.onPrimaryContainer,
                                foregroundColor:
                                    theme.colorScheme.primaryContainer,
                                child: const Icon(Icons.gps_fixed_outlined),
                              ),
                              title: Text(L10n.of(context).shareLocation),
                              contentPadding: const EdgeInsets.all(0),
                            ),
                          ),
                        // Опрос в обычных чатах скрыт (AppConfig.pollsEnabled=
                        // false); в личке с ботом Liza News редактор так
                        // создаёт опрос для рассылки.
                        if (AppConfig.pollsEnabled ||
                            isNewsBotDm(controller.room))
                          PopupMenuItem(
                            value: AddPopupMenuActions.poll,
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.onPrimaryContainer,
                                foregroundColor:
                                    theme.colorScheme.primaryContainer,
                                child: const Icon(Icons.poll_outlined),
                              ),
                              title: Text(L10n.of(context).startPoll),
                              contentPadding: const EdgeInsets.all(0),
                            ),
                          ),
                        // Создание mini App — только в диалоге с BotFather:
                        // команда /newapp уходит именно этому боту, он отвечает
                        // карточкой «Внешний mini App».
                        if (isBotFatherRoom(controller.room))
                          PopupMenuItem(
                            value: AddPopupMenuActions.createMiniApp,
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.onPrimaryContainer,
                                foregroundColor:
                                    theme.colorScheme.primaryContainer,
                                child: const Icon(Icons.apps_outlined),
                              ),
                              title: Text(L10n.of(context).botFatherCreateApp),
                              contentPadding: const EdgeInsets.all(0),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Пакеты живут в глобальном account_data вне дерева виджетов,
                  // поэтому правка состава пакетов сама по себе этот гейт не
                  // пересчитает — слушаем нотифаер (LABA-2542).
                  ValueListenableBuilder<int>(
                    valueListenable: Matrix.of(context).accountBundlesVersion,
                    builder: (context, _, _) {
                      final matrix = Matrix.of(context);
                      if (!matrix.isMultiAccount ||
                          !matrix.hasComplexBundles ||
                          matrix.currentBundle.length <= 1) {
                        return const SizedBox.shrink();
                      }
                      return Container(
                        height: height,
                        width: height,
                        alignment: Alignment.center,
                        child: _ChatAccountPicker(controller),
                      );
                    },
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 0.0),
                      child: InputBar(
                        room: controller.room,
                        minLines: 1,
                        maxLines: 8,
                        autofocus: !PlatformInfos.isMobile,
                        keyboardType: TextInputType.multiline,
                        textInputAction: null,
                        onSubmitted: controller.onInputBarSubmitted,
                        onSubmitImage: () => controller.handleImagePaste(),
                        focusNode: controller.inputFocus,
                        controller: controller.sendController,
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.only(
                            left: 6.0,
                            right: 6.0,
                            bottom: 6.0,
                            top: 3.0,
                          ),
                          counter: const SizedBox.shrink(),
                          // В канале пишут посты, а не сообщения: подсказка
                          // композера должна это отражать.
                          hintText: controller.room.isChannel
                              ? L10n.of(context).channelNewPostHint
                              : L10n.of(context).writeAMessage,
                          hintMaxLines: 1,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          filled: false,
                        ),
                        onChanged: controller.onInputBarChanged,
                        suggestionEmojis:
                            getDefaultEmojiLocale(
                              AppSettings.emojiSuggestionLocale.value.isNotEmpty
                                  ? Locale(
                                      AppSettings.emojiSuggestionLocale.value,
                                    )
                                  : Localizations.localeOf(context),
                            ).fold(
                              [],
                              (emojis, category) =>
                                  emojis..addAll(category.emoji),
                            ),
                      ),
                    ),
                  ),
                  Container(
                    height: height,
                    width: height,
                    alignment: Alignment.center,
                    child:
                        PlatformInfos.platformCanRecord &&
                            controller.sendController.text.isEmpty
                        ? IconButton(
                            onPressed: () => recordingViewModel.startRecording(
                              controller.room,
                              onMaxDurationReached:
                                  controller.onVoiceMessageSend,
                            ),
                            style: IconButton.styleFrom(
                              backgroundColor: theme.bubbleColor,
                              foregroundColor: theme.onBubbleColor,
                            ),
                            icon: const Icon(Icons.mic_none_outlined),
                          )
                        : IconButton(
                            tooltip: L10n.of(context).send,
                            onPressed: controller.send,
                            style: IconButton.styleFrom(
                              backgroundColor: theme.bubbleColor,
                              foregroundColor: theme.onBubbleColor,
                            ),
                            icon: const Icon(Icons.send_outlined),
                          ),
                  ),
                ],
        );
      },
    );
  }
}

class _ChatAccountPicker extends StatelessWidget {
  final ChatController controller;

  const _ChatAccountPicker(this.controller);

  void _popupMenuButtonSelected(String mxid, BuildContext context) {
    final client = Matrix.of(
      context,
    ).currentBundle.firstWhere((cl) => cl?.userID == mxid, orElse: () => null);
    if (client == null) {
      Logs().w('Attempted to switch to a non-existing client $mxid');
      return;
    }
    controller.setSendingClient(client);
  }

  @override
  Widget build(BuildContext context) {
    final clients = controller.currentRoomBundle;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: FutureBuilder<Profile>(
        future: controller.sendingClient.fetchOwnProfile(),
        builder: (context, snapshot) => PopupMenuButton<String>(
          useRootNavigator: true,
          onSelected: (mxid) => _popupMenuButtonSelected(mxid, context),
          itemBuilder: (BuildContext context) => clients
              .map(
                (client) => PopupMenuItem(
                  value: client!.userID,
                  child: FutureBuilder<Profile>(
                    future: client.fetchOwnProfile(),
                    builder: (context, snapshot) => ListTile(
                      leading: Avatar(
                        mxContent: snapshot.data?.avatarUrl,
                        name:
                            snapshot.data?.displayName ??
                            client.userID!.localpart,
                        size: 20,
                      ),
                      title: Text(snapshot.data?.displayName ?? client.userID!),
                      contentPadding: const EdgeInsets.all(0),
                    ),
                  ),
                ),
              )
              .toList(),
          child: Avatar(
            mxContent: snapshot.data?.avatarUrl,
            name:
                snapshot.data?.displayName ??
                Matrix.of(context).client.userID!.localpart,
            size: 20,
          ),
        ),
      ),
    );
  }
}
