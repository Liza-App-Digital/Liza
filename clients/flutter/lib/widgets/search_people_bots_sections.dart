import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/search_title.dart';
import 'package:liza/utils/federated_user_search_service.dart';

/// Ключи заголовков разделов — по ним стражи находят раздел на экране.
const peopleSectionKey = ValueKey('search_section_people');
const botsAndAiSectionKey = ValueKey('search_section_bots_and_ai');

/// Разделы «Люди» / «Боты и ИИ» выдачи поиска — общая разметка трёх экранов
/// (RL-search-people-vs-bots-sections). Возвращает пары «заголовок + тело»
/// только для непустых разделов: пустой раздел скрыт вместе с заголовком.
/// Тело раздела рисует экран через [buildBody] (карусель на главном экране,
/// вертикальный список на остальных).
List<Widget> peopleAndBotsSections(
  BuildContext context,
  PeopleAndBots? sections, {
  required Widget Function(List<Profile> profiles) buildBody,
}) {
  if (sections == null) return const [];
  final l10n = L10n.of(context);
  return [
    if (sections.people.isNotEmpty) ...[
      SearchTitle(
        key: peopleSectionKey,
        title: l10n.searchSectionPeople,
        icon: const Icon(Icons.group_outlined),
      ),
      buildBody(sections.people),
    ],
    if (sections.botsAndAi.isNotEmpty) ...[
      SearchTitle(
        key: botsAndAiSectionKey,
        title: l10n.searchSectionBotsAndAi,
        icon: const Icon(Icons.smart_toy_outlined),
      ),
      buildBody(sections.botsAndAi),
    ],
  ];
}
