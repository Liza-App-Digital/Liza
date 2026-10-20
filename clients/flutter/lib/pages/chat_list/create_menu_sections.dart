enum CreateMenuAction {
  newRequest,
  group,
  channel,
  developers,
  mcp,
  invite,
  contacts,
}

/// Пункты, видимые только роли developer: рядом с подписью ставится
/// `DeveloperMark` (RL-developer-mark).
const developerOnlyActions = {CreateMenuAction.mcp};

/// Разделы меню «+» шапки списка чатов; между разделами — разделитель.
///
/// Состав и порядок — задание Надежды 18.10 (спека
/// `2026-10-19-nadya-interface-1810-design.md`, задача 02): «Новый запрос»,
/// «Создать группу», «Создать канал» | «Разработчику» (всем; бот, mini-app и
/// агент живут в главном меню BotFather) + «Добавить МСР» только разработчику |
/// «Пригласить контакт» + «Контакты» только на мобильных (flutter_contacts на
/// web/десктопе бросает MissingPluginException). «Создать канал» — всем:
/// серверный `channel_guard` роль больше не проверяет.
List<List<CreateMenuAction>> createMenuSections({
  required bool isDeveloper,
  required bool isMobile,
}) => [
  [
    CreateMenuAction.newRequest,
    CreateMenuAction.group,
    CreateMenuAction.channel,
  ],
  [CreateMenuAction.developers, if (isDeveloper) CreateMenuAction.mcp],
  [CreateMenuAction.invite, if (isMobile) CreateMenuAction.contacts],
];
