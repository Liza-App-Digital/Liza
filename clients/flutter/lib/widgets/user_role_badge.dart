import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/role_view.dart';
import 'package:liza/utils/user_role_service.dart';
import 'package:liza/widgets/matrix.dart';

/// Тег роли рядом с username. Подпись и цвет приходят с сервера через каталог
/// user_roles (код, русская подпись, опциональный hex-цвет). Исключение —
/// носители роли `ai`, не являющиеся настоящим ИИ (боты BotFather, @support):
/// им показываем клиентскую плашку «Бот» вместо каталожного «ИИ» (см. _render).
/// Когда у юзера нет роли (или роль не в кэше клиента) — виджет ничего
/// не рисует.
class UserRoleBadge extends StatelessWidget {
  final String? userId;
  final RoleView? _explicitRole;
  final double fontSize;
  final EdgeInsetsGeometry padding;

  /// Коды ролей, для которых плашку НЕ рисуем в этом месте, даже если роль есть в
  /// каталоге. Фильтр по стабильному `role.code` (не по подписи — она приходит с
  /// сервера). Пустой набор по умолчанию → поведение всех прежних call-site не
  /// меняется. Поиск людей передаёт сюда `{admin, moderator}`, чтобы служебные
  /// плашки не мелькали в результатах.
  final Set<String> hideRoleCodes;

  const UserRoleBadge({
    required String this.userId,
    this.fontSize = 10,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    this.hideRoleCodes = const <String>{},
    super.key,
  }) : _explicitRole = null;

  /// Конструктор для тестов: рендерит указанную роль без обращения к
  /// Matrix.of(context) и UserRoleService.
  @visibleForTesting
  const UserRoleBadge.forTest({
    required RoleView? role,
    this.fontSize = 10,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    this.hideRoleCodes = const <String>{},
    super.key,
  })  : userId = null,
        _explicitRole = role;

  /// Дефолт фона если в каталоге не задан цвет. Совпадает с зелёным,
  /// которым раньше отрисовывалась захардкоженная роль `ai`.
  static const Color _defaultBg = Color(0xFF4CAF50);

  @override
  Widget build(BuildContext context) {
    if (_explicitRole != null || userId == null) {
      return _render(context, _explicitRole);
    }
    final service = Matrix.of(context).userRoleService;
    return ValueListenableBuilder(
      valueListenable: service.rolesVersion,
      builder: (context, _, _) => _render(context, service.getRole(userId!)),
    );
  }

  Widget _render(BuildContext context, RoleView? role) {
    if (role == null) return const SizedBox.shrink();
    // Точечное скрытие плашки в конкретном месте (напр. служебные admin/moderator
    // в результатах поиска людей). Фильтр по стабильному коду роли, не по подписи.
    if (hideRoleCodes.contains(role.code)) return const SizedBox.shrink();
    // Дефолтная роль "user" (Пользователь) есть у всех зарегистрированных
    // аккаунтов: она нужна как поведенческий маркер (гейтинг UI по
    // currentUserRole), но НЕ должна показываться тегом - иначе у любого
    // юзера в списке чатов висит зелёный лейбл "Пользователь".
    if (role.code == UserRoleService.userRole) return const SizedBox.shrink();
    // Роль `ai` навешивается сервером на ВСЕ бот-аккаунты (liza —
    // настоящий ИИ; боты BotFather, служба поддержки @support, вручную помеченные
    // люди — не ИИ). Каталог отдаёт для роли `ai` label «ИИ» независимо от того,
    // кто носитель. Различаем по localpart:
    //   • настоящий AI (liza) → каталожный тег «ИИ»;
    //   • прочие носители роли `ai` → зелёная плашка «Бот» (клиентский L10n-текст,
    //     НЕ role.label — иначе покажется «ИИ»). @support сюда тоже попадает —
    //     продуктовое решение: показывать его как обычного бота.
    // Роль `ai` при этом не снимается — она гейтит поведение (нативные
    // кнопки/карточки через isAiUser). (Поглощает прежний _isSupportServiceBot.)
    final isNonAiBot = role.code == UserRoleService.aiRole &&
        userId != null &&
        !UserRoleService.isRealAiLocalpart(userId!);
    final bg = role.color ?? _defaultBg;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isNonAiBot ? L10n.of(context).roleBadgeBot : role.label,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: _contrastForeground(bg),
        ),
      ),
    );
  }

  /// Подбираем цвет текста под фон: тёмные фоны получают белый текст,
  /// светлые — чёрный. Это работает для любых цветов из каталога без
  /// необходимости хранить пары bg/fg явно.
  Color _contrastForeground(Color bg) {
    final luminance = bg.computeLuminance();
    return luminance > 0.5 ? Colors.black : Colors.white;
  }
}
