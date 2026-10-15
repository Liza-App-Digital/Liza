enum CreateMenuAction {
  newRequest,
  group,
  channel,
  story,
  bot,
  miniApp,
  agent,
  mcp,
  invite,
  contacts,
}

/// Разделы меню «+» шапки списка чатов; между разделами — разделитель.
///
/// Порядок — постановка продакта 2026-09-16 (спека
/// `2026-09-16-create-menu-connect-agent-design.md`); «Новый запрос» к Лизе —
/// первым (РГ Лиза 05.10, спека `2026-10-14-liza-new-request-chat-design.md`). «Добавить МСР» — отдельным
/// разделом только для разработчика (и админа); у остальных нет ни пункта, ни
/// лишнего разделителя. «Контакты» — только на мобильных: flutter_contacts на
/// web/десктопе бросает MissingPluginException.
List<List<CreateMenuAction>> createMenuSections({
  required bool isAdmin,
  required bool isDeveloper,
  required bool isMobile,
}) => [
  [
    CreateMenuAction.newRequest,
    CreateMenuAction.group,
    if (isAdmin) CreateMenuAction.channel,
    CreateMenuAction.story,
    CreateMenuAction.bot,
    CreateMenuAction.miniApp,
    CreateMenuAction.agent,
  ],
  if (isDeveloper || isAdmin) [CreateMenuAction.mcp],
  [CreateMenuAction.invite, if (isMobile) CreateMenuAction.contacts],
];
