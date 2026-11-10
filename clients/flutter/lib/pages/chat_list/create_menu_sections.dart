enum CreateMenuAction { newRequest, group, channel, developers, mcp, invite }

/// Пункты, видимые только роли developer: рядом с подписью ставится
/// `DeveloperMark` (RL-developer-mark).
const developerOnlyActions = {CreateMenuAction.channel, CreateMenuAction.mcp};

/// Пункты с визуальным акцентом (шестиугольник «+» и жирная подпись) — главное
/// действие меню (замечание Надежды 23.10: «сейчас все пункты равнозначны»).
const highlightedActions = {CreateMenuAction.newRequest};

/// Разделы меню «+» шапки списка чатов; между разделами — разделитель.
///
/// Состав и порядок — задание Надежды 18.10 (спека
/// `2026-10-19-nadya-interface-1810-design.md`, задача 02): «Новый запрос»,
/// «Создать группу» | «Разработчику» (всем; бот, mini-app и агент живут в
/// главном меню BotFather) + «Создать канал» и «Добавить МСР» только
/// разработчику | «Пригласить контакт». «Контакты» живут только в меню аватара —
/// на всех платформах одинаково (замечание Надежды 20.10,
/// RL-contacts-entry-avatar-all-platforms).
/// Каналы в разработке — весь их функционал за ролью developer (06.11,
/// RL-channels-developer-only); серверный `channel_guard` роль не проверяет.
List<List<CreateMenuAction>> createMenuSections({required bool isDeveloper}) =>
    [
      [CreateMenuAction.newRequest, CreateMenuAction.group],
      [
        CreateMenuAction.developers,
        if (isDeveloper) ...[CreateMenuAction.channel, CreateMenuAction.mcp],
      ],
      [CreateMenuAction.invite],
    ];
