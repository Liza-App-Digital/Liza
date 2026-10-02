import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:matrix/matrix.dart';
import 'package:slugify/slugify.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/bot_commands_registry.dart';
import 'package:liza/utils/markdown_context_builder.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/widgets/mxc_image.dart';
import '../../widgets/avatar.dart';
import '../../widgets/matrix.dart';
import '../../widgets/user_role_badge.dart';
import 'command_hints.dart';

/// Выделенная подсказка-команда `/menu` для чата с BotFather (LABA-2201).
///
/// При вводе «/…» в диалоге с BotFather команду `/menu` показываем первой и
/// выделенной — очевидный способ вернуться к стартовому меню. Возвращает запись
/// подсказки (`highlight=true`), если [room] — чат BotFather и строка поиска
/// [commandSearch] (то, что после «/», нижним регистром) является префиксом
/// «menu» (пусто, `m`, `me`, `men`, `menu`). Иначе — null. Вынесено из виджета
/// для юнит-теста без монтирования (ledger:RL-botfather-menu-command).
Map<String, String?>? botFatherMenuCommandSuggestion(
  Room room,
  String commandSearch,
) {
  if ('menu'.contains(commandSearch) && isBotFatherRoom(room)) {
    return {'type': 'command', 'name': 'menu', 'highlight': 'true'};
  }
  return null;
}

/// Подсказки «/» из меню бота-собеседника DM (ledger:RL-bot-commands-composer-menu).
/// Пусто вне DM и пока команды не загружены. Совпадение — по префиксу.
List<Map<String, String?>> botCommandSuggestions(
  Room room,
  String commandSearch,
) {
  final botMxid = room.directChatMatrixID;
  if (botMxid == null) return const [];
  return [
    for (final c in BotCommandsRegistry.instance.commandsFor(
      room.client,
      botMxid,
    ))
      if (c.command.startsWith(commandSearch))
        {'type': 'botcommand', 'name': c.command, 'description': c.description},
  ];
}

class InputBar extends StatefulWidget {
  /// Позиция каретки, пригодная для `substring`. `-1` (каретки нет вовсе) —
  /// НЕ исключительная ситуация: `Autocomplete` зовёт `displayStringForOption`
  /// уже ПОСЛЕ очистки композера в `send()`, а сеттер `TextEditingController.text`
  /// принудительно ставит `TextSelection.collapsed(offset: -1)`. Тогда каретку
  /// считаем концом текста — та же конвенция, что в `Chat.insertEmojiIntoText`.
  static int caretOffset(String text, int baseOffset) =>
      baseOffset < 0 ? text.length : baseOffset.clamp(0, text.length);

  final Room room;
  final int? minLines;
  final int? maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onSubmitImage;
  final FocusNode? focusNode;
  final TextEditingController? controller;
  final InputDecoration decoration;
  final ValueChanged<String>? onChanged;
  final bool? autofocus;
  final bool readOnly;
  final List<Emoji> suggestionEmojis;

  const InputBar({
    required this.room,
    this.minLines,
    this.maxLines,
    this.keyboardType,
    this.onSubmitted,
    this.onSubmitImage,
    this.focusNode,
    this.controller,
    required this.decoration,
    this.onChanged,
    this.autofocus,
    this.textInputAction,
    this.readOnly = false,
    required this.suggestionEmojis,
    super.key,
  });

  // Future-загрузки полного списка участников по room.id. Статика, чтобы
  // переживать пересоздания InputBar и не дёргать /members на каждый ввод
  // `@`. Если future ещё не завершён — все вызовы `optionsBuilder` ожидают
  // его. Если завершён — повторно не запрашиваем. При ошибке ключ
  // удаляется, чтобы следующий ввод `@` ретрайнул загрузку.
  static final Map<String, Future<void>> _participantsLoad = {};

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  Room get room => widget.room;
  TextEditingController? get controller => widget.controller;
  List<Emoji> get suggestionEmojis => widget.suggestionEmojis;
  FocusNode? get focusNode => widget.focusNode;

  Future<void> _ensureParticipantsLoaded() {
    final roomId = widget.room.id;
    final existing = InputBar._participantsLoad[roomId];
    if (existing != null) {
      return existing;
    }
    final future = widget.room
        .requestParticipants(
          [...Membership.values]..remove(Membership.leave),
          false, // suppressWarning
          true, // cache: true — кэшировать в БД и в неэнкрипт чатах
        )
        .then((_) {})
        .catchError((Object e, StackTrace st) {
          // Снимаем флаг, чтобы следующий ввод `@` ретрайнул запрос.
          InputBar._participantsLoad.remove(roomId);
          Logs().w('requestParticipants failed for $roomId', e, st);
        });
    InputBar._participantsLoad[roomId] = future;
    return future;
  }

  Future<List<Map<String, String?>>> _getSuggestionsWithAiPinning(
    TextEditingValue text,
    BuildContext context,
  ) async {
    // Если пользователь начал упоминание (@…), сначала лениво дотягиваем
    // полный список участников (один раз на чат за сессию). Autocomplete
    // дождётся future и пересчитает options после загрузки — поэтому
    // отдельный лоадер-tile в попровере не нужен.
    if (_hasUserMatch(text)) {
      await _ensureParticipantsLoaded();
    }
    final suggestions = getSuggestions(text);
    // Pin AI accounts first in mention suggestions (Liza first among AI)
    final matrix = Matrix.of(context);
    final aiItems = suggestions
        .where((s) => s['type'] == 'user' && matrix.isAiUser(s['mxid'] ?? ''))
        .toList();
    if (aiItems.isNotEmpty) {
      suggestions.removeWhere(
        (s) => s['type'] == 'user' && matrix.isAiUser(s['mxid'] ?? ''),
      );
      aiItems.sort((a, b) {
        if (a['mxid'] == MatrixState.lizaMxid) return -1;
        if (b['mxid'] == MatrixState.lizaMxid) return 1;
        return 0;
      });
      suggestions.insertAll(0, aiItems);
    }
    return suggestions;
  }

  bool _hasUserMatch(TextEditingValue text) {
    if (text.selection.baseOffset != text.selection.extentOffset ||
        text.selection.baseOffset < 0) {
      return false;
    }
    final searchText = text.text.substring(0, text.selection.baseOffset);
    return RegExp(
          r'(?:\s|^)@([-\w\p{L}]*)$',
          unicode: true,
        ).firstMatch(searchText) !=
        null;
  }

  List<Map<String, String?>> getSuggestions(TextEditingValue text) {
    if (text.selection.baseOffset != text.selection.extentOffset ||
        text.selection.baseOffset < 0) {
      return []; // no entries if there is selected text
    }
    final searchText = text.text.substring(0, text.selection.baseOffset);
    final ret = <Map<String, String?>>[];
    const maxResults = 30;

    final commandMatch = RegExp(r'^/(\w*)$').firstMatch(searchText);
    if (commandMatch != null) {
      final commandSearch = commandMatch[1]!.toLowerCase();
      // BotFather: команда /menu возвращает стартовое меню (LABA-2201). Даём её
      // первой и выделенной — очевидный способ вернуться к меню, а не искать
      // /start или скроллить в начало диалога. Не Matrix-команда: уходит боту
      // текстом (см. botCommands в chat.dart send()).
      final menuSuggestion = botFatherMenuCommandSuggestion(
        room,
        commandSearch,
      );
      if (menuSuggestion != null) {
        ret.add(menuSuggestion);
      }
      // Меню бота (setMyCommands в Liza Bot API) — первым: в чате с ботом это то,
      // что пользователь ищет. Загружает BotCommandsRegistry при открытии чата.
      ret.addAll(botCommandSuggestions(room, commandSearch));
      for (final command in room.client.commands.keys) {
        if (command.contains(commandSearch)) {
          ret.add({'type': 'command', 'name': command});
        }

        if (ret.length > maxResults) return ret;
      }
    }
    final emojiMatch = RegExp(
      r'(?:\s|^):(?:([\p{L}\p{N}_-]+)~)?([\p{L}\p{N}_-]+)$',
      unicode: true,
    ).firstMatch(searchText);
    if (emojiMatch != null) {
      final packSearch = emojiMatch[1];
      final emoteSearch = emojiMatch[2]!.toLowerCase();
      final emotePacks = room.getImagePacks(ImagePackUsage.emoticon);
      if (packSearch == null || packSearch.isEmpty) {
        for (final pack in emotePacks.entries) {
          for (final emote in pack.value.images.entries) {
            if (emote.key.toLowerCase().contains(emoteSearch)) {
              ret.add({
                'type': 'emote',
                'name': emote.key,
                'pack': pack.key,
                'pack_avatar_url': pack.value.pack.avatarUrl?.toString(),
                'pack_display_name': pack.value.pack.displayName ?? pack.key,
                'mxc': emote.value.url.toString(),
              });
            }
            if (ret.length > maxResults) {
              break;
            }
          }
          if (ret.length > maxResults) {
            break;
          }
        }
      } else if (emotePacks[packSearch] != null) {
        for (final emote in emotePacks[packSearch]!.images.entries) {
          if (emote.key.toLowerCase().contains(emoteSearch)) {
            ret.add({
              'type': 'emote',
              'name': emote.key,
              'pack': packSearch,
              'pack_avatar_url': emotePacks[packSearch]!.pack.avatarUrl
                  ?.toString(),
              'pack_display_name':
                  emotePacks[packSearch]!.pack.displayName ?? packSearch,
              'mxc': emote.value.url.toString(),
            });
          }
          if (ret.length > maxResults) {
            break;
          }
        }
      }

      // aside of emote packs, also propose normal (tm) unicode emojis
      final matchingUnicodeEmojis = suggestionEmojis
          .where((emoji) => emoji.name.toLowerCase().contains(emoteSearch))
          .toList();

      // sort by the index of the search term in the name in order to have
      // best matches first
      // (thanks for the hint by github.com/nextcloud/circles devs)
      matchingUnicodeEmojis.sort((a, b) {
        final indexA = a.name.indexOf(emoteSearch);
        final indexB = b.name.indexOf(emoteSearch);
        if (indexA == -1 || indexB == -1) {
          if (indexA == indexB) return 0;
          if (indexA == -1) {
            return 1;
          } else {
            return 0;
          }
        }
        return indexA.compareTo(indexB);
      });
      for (final emoji in matchingUnicodeEmojis) {
        ret.add({
          'type': 'emoji',
          'emoji': emoji.emoji,
          'label': emoji.name,
          'current_word': ':$emoteSearch',
        });
        if (ret.length > maxResults) {
          break;
        }
      }
    }
    final userMatch = RegExp(
      r'(?:\s|^)@([-\w\p{L}]*)$',
      unicode: true,
    ).firstMatch(searchText);
    if (userMatch != null) {
      // Полный список участников гарантированно подгружается перед вызовом
      // getSuggestions через _ensureParticipantsLoaded в _getSuggestionsWithAiPinning.
      // Здесь итерируем уже свежий room.getParticipants().
      final userSearch = userMatch[1]!.toLowerCase();
      for (final user in room.getParticipants()) {
        if (user.id == room.client.userID) continue;
        if (userSearch.isEmpty ||
            (user.displayName != null &&
                (user.displayName!.toLowerCase().contains(userSearch) ||
                    slugify(
                      user.displayName!.toLowerCase(),
                    ).contains(userSearch))) ||
            user.id.split(':')[0].toLowerCase().contains(userSearch)) {
          ret.add({
            'type': 'user',
            'mxid': user.id,
            'mention': user.mention,
            'displayname': user.displayName,
            'avatar_url': user.avatarUrl?.toString(),
          });
        }
        if (ret.length > maxResults) {
          break;
        }
      }
    }
    final roomMatch = RegExp(r'(?:\s|^)#([-\w]+)$').firstMatch(searchText);
    if (roomMatch != null) {
      final roomSearch = roomMatch[1]!.toLowerCase();
      for (final r in room.client.rooms) {
        if (r.getState(EventTypes.RoomTombstone) != null) {
          continue; // we don't care about tombstoned rooms
        }
        final state = r.getState(EventTypes.RoomCanonicalAlias);
        if ((state != null &&
                ((state.content['alias'] is String &&
                        state.content
                            .tryGet<String>('alias')!
                            .split(':')[0]
                            .toLowerCase()
                            .contains(roomSearch)) ||
                    (state.content['alt_aliases'] is List &&
                        (state.content['alt_aliases'] as List).any(
                          (l) =>
                              l is String &&
                              l
                                  .split(':')[0]
                                  .toLowerCase()
                                  .contains(roomSearch),
                        )))) ||
            (r.name.toLowerCase().contains(roomSearch))) {
          ret.add({
            'type': 'room',
            'mxid': (r.canonicalAlias.isNotEmpty) ? r.canonicalAlias : r.id,
            'displayname': r.getLocalizedDisplayname(),
            'avatar_url': r.avatar?.toString(),
          });
        }
        if (ret.length > maxResults) {
          break;
        }
      }
    }
    return ret;
  }

  Widget buildSuggestion(
    BuildContext context,
    Map<String, String?> suggestion,
    void Function(Map<String, String?>) onSelected,
    Client? client,
  ) {
    final theme = Theme.of(context);
    const size = 30.0;
    if (suggestion['type'] == 'botcommand') {
      return ListTile(
        onTap: () => onSelected(suggestion),
        title: Text(
          '/${suggestion['name']!}',
          style: const TextStyle(fontFamily: 'RobotoMono'),
        ),
        subtitle: (suggestion['description'] ?? '').isEmpty
            ? null
            : Text(
                suggestion['description']!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
      );
    }
    if (suggestion['type'] == 'command') {
      final command = suggestion['name']!;
      final hint = commandHint(L10n.of(context), command);
      // Выделенная команда (напр. /menu у BotFather, LABA-2201): подсветка
      // фона, иконка меню и акцентный жирный текст — чтобы бросалась в глаза
      // среди прочих подсказок.
      final highlight = suggestion['highlight'] == 'true';
      return Tooltip(
        message: hint,
        waitDuration: const Duration(days: 1), // don't show on hover
        child: ListTile(
          onTap: () => onSelected(suggestion),
          tileColor: highlight
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
              : null,
          leading: highlight
              ? Icon(Icons.menu, color: theme.colorScheme.primary)
              : null,
          title: Text(
            commandExample(command),
            style: TextStyle(
              fontFamily: 'RobotoMono',
              fontWeight: highlight ? FontWeight.bold : null,
              color: highlight ? theme.colorScheme.primary : null,
            ),
          ),
          subtitle: Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }
    if (suggestion['type'] == 'emoji') {
      final label = suggestion['label']!;
      return Tooltip(
        message: label,
        waitDuration: const Duration(days: 1), // don't show on hover
        child: ListTile(
          onTap: () => onSelected(suggestion),
          leading: SizedBox.square(
            dimension: size,
            child: Text(
              suggestion['emoji']!,
              style: const TextStyle(fontSize: 16),
            ),
          ),
          title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      );
    }
    if (suggestion['type'] == 'emote') {
      return ListTile(
        onTap: () => onSelected(suggestion),
        leading: MxcImage(
          // ensure proper ordering ...
          key: ValueKey(suggestion['name']),
          uri: suggestion['mxc'] is String
              ? Uri.parse(suggestion['mxc'] ?? '')
              : null,
          width: size,
          height: size,
          isThumbnail: false,
        ),
        title: Row(
          crossAxisAlignment: .center,
          children: <Widget>[
            Text(suggestion['name']!),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Opacity(
                  opacity: suggestion['pack_avatar_url'] != null ? 0.8 : 0.5,
                  child: suggestion['pack_avatar_url'] != null
                      ? Avatar(
                          mxContent: Uri.tryParse(
                            suggestion.tryGet<String>('pack_avatar_url') ?? '',
                          ),
                          name: suggestion.tryGet<String>('pack_display_name'),
                          size: size * 0.9,
                          client: client,
                        )
                      : Text(suggestion['pack_display_name']!),
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (suggestion['type'] == 'user' || suggestion['type'] == 'room') {
      final url = Uri.parse(suggestion['avatar_url'] ?? '');
      final mxid = suggestion.tryGet<String>('mxid') ?? '';
      final isUser = suggestion['type'] == 'user';
      return ListTile(
        onTap: () => onSelected(suggestion),
        leading: Avatar(
          mxContent: url,
          name: suggestion.tryGet<String>('displayname') ?? mxid,
          size: size,
          client: client,
          isHexagonal: isUser && Matrix.of(context).isAiUser(mxid),
        ),
        title: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          children: [
            Text(suggestion['displayname'] ?? suggestion['mxid']!),
            if (isUser)
              UserRoleBadge(
                userId: mxid,
                fontSize: 9,
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  String insertSuggestion(Map<String, String?> suggestion) {
    final text = controller!.text;
    // GlitchTip issue 184 (29 событий, 13 юзеров, 3 месяца): `''.substring(0, -1)`
    // ронял `_onChangedField` в uncaught async zone — подсказки после отправки
    // переставали обновляться, а `_selection` внутри Autocomplete залипал не-null,
    // из-за чего следующая отправка с пустого поля бросала снова (серии событий).
    final cursor = InputBar.caretOffset(text, controller!.selection.baseOffset);
    final replaceText = text.substring(0, cursor);
    var startText = '';
    // Ветка исполняется только когда `replaceText != text`, а `replaceText` —
    // это `text.substring(0, cursor)`; значит здесь гарантированно
    // `cursor < text.length`, и `cursor + 1` за границу не выходит.
    final afterText = replaceText == text ? '' : text.substring(cursor + 1);
    var insertText = '';
    if (suggestion['type'] == 'command' || suggestion['type'] == 'botcommand') {
      insertText = '${suggestion['name']!} ';
      startText = replaceText.replaceAllMapped(
        RegExp(r'^(/\w*)$'),
        (Match m) => '/$insertText',
      );
    }
    if (suggestion['type'] == 'emoji') {
      insertText = '${suggestion['emoji']!} ';
      startText = replaceText.replaceAllMapped(
        suggestion['current_word']!,
        (Match m) => insertText,
      );
    }
    if (suggestion['type'] == 'emote') {
      var isUnique = true;
      final insertEmote = suggestion['name'];
      final insertPack = suggestion['pack'];
      final emotePacks = room.getImagePacks(ImagePackUsage.emoticon);
      for (final pack in emotePacks.entries) {
        if (pack.key == insertPack) {
          continue;
        }
        for (final emote in pack.value.images.entries) {
          if (emote.key == insertEmote) {
            isUnique = false;
            break;
          }
        }
        if (!isUnique) {
          break;
        }
      }
      insertText = ':${isUnique ? '' : '${insertPack!}~'}$insertEmote: ';
      startText = replaceText.replaceAllMapped(
        RegExp(r'(\s|^)(:(?:[-\w]+~)?[-\w]+)$'),
        (Match m) => '${m[1]}$insertText',
      );
    }
    if (suggestion['type'] == 'user') {
      insertText = '${suggestion['mention']!} ';
      startText = replaceText.replaceAllMapped(
        RegExp(r'(\s|^)(@[-\w\p{L}]*)$', unicode: true),
        (Match m) => '${m[1]}$insertText',
      );
    }
    if (suggestion['type'] == 'room') {
      insertText = '${suggestion['mxid']!} ';
      startText = replaceText.replaceAllMapped(
        RegExp(r'(\s|^)(#[-\w]+)$'),
        (Match m) => '${m[1]}$insertText',
      );
    }

    return startText + afterText;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Autocomplete<Map<String, String?>>(
      focusNode: focusNode,
      textEditingController: controller,
      optionsBuilder: (text) => _getSuggestionsWithAiPinning(text, context),
      onSelected: (suggestion) {
        // /menu (BotFather) — исполняем сразу по выбору из подсказок, без
        // ручного Enter (LABA-2201): команда без аргументов, поведение как в
        // Liza. К этому моменту Autocomplete уже подставил в поле «/menu ».
        // ВАЖНО: onSelected вызывается ВНУТРИ обновления поля самим Autocomplete
        // (он в этот момент правит controller/фокус). Синхронный send() отсюда
        // (setState + очистка controller) конфликтует с этим обновлением и
        // оставляет поле ввода «мёртвым» — печатать больше нельзя. Поэтому
        // откладываем отправку на следующий кадр, когда Autocomplete завершил
        // своё обновление.
        if (suggestion['type'] == 'command' && suggestion['name'] == 'menu') {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            widget.onSubmitted?.call(controller?.text ?? '');
          });
        }
      },
      fieldViewBuilder: (context, controller, focusNode, _) => TextField(
        controller: controller,
        focusNode: focusNode,
        readOnly: widget.readOnly,
        contextMenuBuilder: (c, e) => markdownContextBuilder(
          c,
          e,
          controller,
          onPasteImage: widget.onSubmitImage,
        ),
        contentInsertionConfiguration: ContentInsertionConfiguration(
          onContentInserted: (KeyboardInsertedContent content) {
            final data = content.data;
            if (data == null) return;

            final insertedName = content.uri.split('/').last;
            final file = MatrixFile(
              mimeType: content.mimeType,
              bytes: data,
              // Вставка из клавиатуры/буфера часто даёт пустой uri → пустое имя,
              // из-за которого у получателя диалог «Сохранить как» пустой.
              name: insertedName.isEmpty ? 'pasted_image' : insertedName,
            );
            widget.room.sendFileEvent(file, shrinkImageMaxDimension: 1600);
          },
        ),
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        keyboardType: widget.keyboardType!,
        textInputAction: widget.textInputAction,
        autofocus: widget.autofocus!,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        inputFormatters: [
          LengthLimitingTextInputFormatter((maxPDUSize / 3).floor()),
        ],
        onSubmitted: (text) {
          // fix for library for now
          // it sets the types for the callback incorrectly
          widget.onSubmitted!(text);
        },
        maxLength: AppSettings.textMessageMaxLength.value,
        decoration: widget.decoration,
        onChanged: (text) {
          // fix for the library for now
          // it sets the types for the callback incorrectly
          widget.onChanged!(text);
        },
        textCapitalization: TextCapitalization.sentences,
      ),
      optionsViewBuilder: (c, onSelected, s) {
        final suggestions = s.toList();
        // Ограничиваем высоту попровера ~5 элементами; внутри уже есть скролл
        // через ListView. Иначе при @ без фильтра список разворачивается на
        // весь экран.
        return Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            elevation: theme.appBarTheme.scrolledUnderElevation ?? 4,
            shadowColor: theme.appBarTheme.shadowColor,
            borderRadius: BorderRadius.circular(AppConfig.borderRadius),
            clipBehavior: Clip.hardEdge,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: suggestions.length,
                itemBuilder: (context, i) => buildSuggestion(
                  c,
                  suggestions[i],
                  onSelected,
                  Matrix.of(context).client,
                ),
              ),
            ),
          ),
        );
      },
      displayStringForOption: insertSuggestion,
      optionsViewOpenDirection: OptionsViewOpenDirection.up,
    );
  }
}
