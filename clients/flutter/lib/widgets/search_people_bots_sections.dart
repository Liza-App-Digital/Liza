import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/search_title.dart';
import 'package:liza/utils/federated_user_search_service.dart';

/// Ключи заголовков разделов — по ним стражи находят раздел на экране.
const peopleSectionKey = ValueKey('search_section_people');
const botsAndAiSectionKey = ValueKey('search_section_bots_and_ai');

/// Раздел «Люди» выдачи поиска: «заголовок + тело» либо ничего, если пуст.
/// Тело рисует экран через [buildBody] (карусель на главном экране,
/// вертикальный список на остальных).
List<Widget> peopleSearchSection(
  BuildContext context,
  PeopleAndBots? sections, {
  required Widget Function(List<Profile> profiles) buildBody,
}) {
  if (sections == null || sections.people.isEmpty) return const [];
  return [
    SearchTitle(
      key: peopleSectionKey,
      title: L10n.of(context).searchSectionPeople,
      icon: const Icon(Icons.group_outlined),
    ),
    buildBody(sections.people),
  ];
}

/// Раздел «Агенты и боты» выдачи поиска — подпись та же, что у чипа списка
/// чатов (`agentsAndBots`), чтобы раздел и вкладка назывались одинаково.
List<Widget> botsSearchSection(
  BuildContext context,
  PeopleAndBots? sections, {
  required Widget Function(List<Profile> profiles) buildBody,
}) {
  if (sections == null || sections.botsAndAi.isEmpty) return const [];
  return [
    SearchTitle(
      key: botsAndAiSectionKey,
      title: L10n.of(context).agentsAndBots,
      icon: const Icon(Icons.smart_toy_outlined),
    ),
    buildBody(sections.botsAndAi),
  ];
}

/// Разделы «Люди» / «Агенты и боты» — разметка «Нового личного чата» и
/// «Пригласить в группу» (RL-search-people-vs-bots-sections): там цель —
/// человек, поэтому «Люди» выше. Главный экран ставит разделы сам, в порядке
/// `searchSectionOrder` (боты первыми, как во вкладках).
List<Widget> peopleAndBotsSections(
  BuildContext context,
  PeopleAndBots? sections, {
  required Widget Function(List<Profile> profiles) buildBody,
}) => [
  ...peopleSearchSection(context, sections, buildBody: buildBody),
  ...botsSearchSection(context, sections, buildBody: buildBody),
];
