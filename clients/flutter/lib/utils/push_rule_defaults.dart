import 'package:collection/collection.dart';
import 'package:matrix/matrix.dart';

/// Дефолтное push-правило Matrix, отклонение которого ломает доставку.
///
/// `defaultEnabled` — из `base_rules.rs` Synapse. [silences] — выключение правила
/// оставляет часть чатов без пуша и счётчика (в отличие от, например,
/// `suppress_edits`, выключение которого, наоборот, даёт ЛИШНИЕ пуши правок).
class DefaultPushRule {
  final PushRuleKind kind;
  final String ruleId;
  final bool defaultEnabled;
  final bool silences;

  const DefaultPushRule(
    this.kind,
    this.ruleId, {
    this.defaultEnabled = true,
    this.silences = false,
  });
}

/// Инцидент 2026-09-14: у пользователя сырые переключатели экрана уведомлений
/// выключили `.m.rule.message` и `.m.rule.suppress_edits` — незашифрованные группы
/// замолчали, правки пушились повторно, а пользователь не мог понять почему.
/// Серверный двойник — детектор 9 `pusher-health-poller.py`; списки согласованы.
abstract class PushRuleDefaults {
  static const List<DefaultPushRule> rules = [
    DefaultPushRule(PushRuleKind.underride, '.m.rule.message', silences: true),
    DefaultPushRule(
      PushRuleKind.underride,
      '.m.rule.encrypted',
      silences: true,
    ),
    DefaultPushRule(
      PushRuleKind.underride,
      '.m.rule.room_one_to_one',
      silences: true,
    ),
    DefaultPushRule(
      PushRuleKind.underride,
      '.m.rule.encrypted_room_one_to_one',
      silences: true,
    ),
    DefaultPushRule(
      PushRuleKind.override,
      '.m.rule.invite_for_me',
      silences: true,
    ),
    DefaultPushRule(PushRuleKind.override, '.m.rule.suppress_edits'),
    DefaultPushRule(PushRuleKind.override, '.m.rule.suppress_notices'),
    DefaultPushRule(PushRuleKind.override, '.m.rule.is_user_mention'),
    DefaultPushRule(PushRuleKind.override, '.m.rule.is_room_mention'),
    DefaultPushRule(PushRuleKind.override, '.m.rule.contains_display_name'),
    DefaultPushRule(PushRuleKind.override, '.m.rule.reaction'),
    DefaultPushRule(PushRuleKind.override, '.m.rule.member_event'),
  ];

  /// Правила из [rules], чьё `enabled` отличается от дефолта.
  ///
  /// `null` — набор правил ещё не загружен (до первого sync / ruleset не
  /// распарсился): это НЕ «всё выключено», баннер и сигнал в этом случае молчат.
  /// Правила, которого сервер не прислал, считаем дефолтным.
  /// `.m.rule.master` сюда не входит — у него свой переключатель на экране.
  static List<DefaultPushRule>? deviations(PushRuleSet? set) {
    if (set == null || (set.override == null && set.underride == null)) {
      return null;
    }
    final byKind = {
      PushRuleKind.override: set.override ?? const <PushRule>[],
      PushRuleKind.underride: set.underride ?? const <PushRule>[],
    };
    return [
      for (final rule in rules)
        if (byKind[rule.kind]!.firstWhereOrNull((r) => r.ruleId == rule.ruleId)
            case final actual? when actual.enabled != rule.defaultEnabled)
          rule,
    ];
  }

  static bool anySilencing(List<DefaultPushRule> deviations) =>
      deviations.any((rule) => rule.silences);

  /// Вернуть дефолты ТОЛЬКО отклонившимся правилам из whitelist — мьюты
  /// отдельных чатов (room/override-правила с id комнаты) не трогаются.
  static Future<void> resetToDefaults(
    List<DefaultPushRule> deviations,
    Future<void> Function(PushRuleKind kind, String ruleId, bool enabled)
    setEnabled,
  ) async {
    for (final rule in deviations) {
      try {
        await setEnabled(rule.kind, rule.ruleId, rule.defaultEnabled);
      } on MatrixException catch (e) {
        // Synapse ≥1.164 (MSC4210) больше не обслуживает легаси-правила
        // (`.m.rule.contains_display_name`, `.roomnotif`) и отвечает 404 на их
        // правку: такое правило пропускаем, остальные отклонения всё равно чиним.
        if (e.error != MatrixError.M_NOT_FOUND) rethrow;
      }
    }
  }
}
