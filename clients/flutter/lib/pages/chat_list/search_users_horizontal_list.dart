import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/search_carousel_item.dart';
import 'package:liza/widgets/adaptive_dialogs/user_dialog.dart';
import 'package:liza/widgets/horizontal_mouse_wheel.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/user_identifier.dart';

/// Карусель людей в поиске главного экрана.
///
/// Вынесена из `chat_list_body.dart` в отдельный публичный виджет по тому же
/// прецеденту, что и `InvitePeopleListTile`: приватный класс внутри тяжёлого
/// `ChatListBody` нельзя отрисовать в страже на реальном виджете
/// (RL-search-handle-profile-hydration).
///
/// Рисует ровно переданный [profiles] — один раздел выдачи («Люди» или
/// «Боты и ИИ», RL-search-people-vs-bots-sections). Контроллер пересчитывает
/// разделы при публикации (стадия 1: находки с `@ник`-фоллбэком), после
/// гидратации (стадия 2: имя и аватар из профиля) и при позднем приходе
/// ролей. Сети из `build()` нет: заголовок и буква аватара считаются
/// синхронно через [searchResultLabel].
class SearchUsersHorizontalList extends StatefulWidget {
  const SearchUsersHorizontalList({
    required this.profiles,
    required this.onItemTap,
    super.key,
  });

  final List<Profile> profiles;
  final void Function(String userId) onItemTap;

  @override
  State<SearchUsersHorizontalList> createState() =>
      _SearchUsersHorizontalListState();
}

class _SearchUsersHorizontalListState extends State<SearchUsersHorizontalList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profiles = widget.profiles;
    final handles = Matrix.of(context).userHandleService;
    final unknown = L10n.of(context).user;
    return AnimatedContainer(
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      height: profiles.isEmpty ? 0 : 106,
      duration: LizaThemes.animationDuration,
      curve: LizaThemes.animationCurve,
      child: HorizontalMouseWheel(
        controller: _scrollController,
        child: PrimaryScrollController.none(
          child: ListView.builder(
            primary: false,
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            itemCount: profiles.length,
            itemBuilder: (context, i) {
              final profile = profiles[i];
              final label = searchResultLabel(
                profile,
                handles: handles,
                unknown: unknown,
              );
              return SearchCarouselItem(
                // Элемент мог переехать между разделами (поздние роли):
                // ключ по userId не даёт переиспользовать чужое состояние.
                key: ValueKey(profile.userId),
                title: label.title,
                avatarName: label.avatarName,
                avatar: profile.avatarUrl,
                userId: profile.userId,
                onPressed: () => widget.onItemTap(profile.userId),
                onLongPress: () {
                  HapticFeedback.heavyImpact();
                  UserDialog.show(context: context, profile: profile);
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
