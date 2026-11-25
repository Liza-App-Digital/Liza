import 'package:matrix/matrix.dart';

/// [Client] Лизы: чинит локальный [PushruleEvaluator] SDK под намеренные упоминания.
///
/// Правила `.m.rule.is_user_mention`/`.is_room_mention`/`.suppress_edits` адресуют
/// поле ключом с экранированной точкой (`content.m\.mentions.user_ids`, MSC3873), а
/// SDK matrix-4.1.0 склеивает путь события через `.` без экранирования
/// (`_flattenJson`) — такие правила локально НЕ матчат никогда. Десктоп/веб-баннер
/// об упоминании в чате «только упоминания» держался на легаси-правиле по имени,
/// которое Synapse ≥1.164 (MSC4210) удаляет. Раскрываем `\.` → `.` в ключах условий
/// перед сборкой эвалюатора: путь совпадает с тем, что строит `_flattenJson`.
///
/// Спека: docs/superpowers/specs/2026-11-24-c-protocol-matrix-mentions-design.md.
class LizaClient extends Client {
  LizaClient(
    super.clientName, {
    required super.database,
    super.verificationMethods,
    super.httpClient,
    super.importantStateEvents,
    super.supportedLoginTypes,
    super.nativeImplementations,
    super.logLevel,
    super.syncFilter,
    super.defaultNetworkRequestTimeout,
    super.sendTimelineEventTimeout,
    super.shareKeysWith,
    super.enableDehydratedDevices,
    super.onSoftLogout,
    super.convertLinebreaksInFormatting,
  });

  Object? _rulesSource;
  PushruleEvaluator? _evaluator;

  @override
  PushruleEvaluator get pushruleEvaluator {
    final source = accountData[EventTypes.PushRules]?.content;
    final cached = _evaluator;
    // Кеш по идентичности content: SDK кладёт новый объект на каждое обновление
    // account data m.push_rules, а сам геттер зовётся на каждое входящее событие.
    if (cached != null && identical(source, _rulesSource)) return cached;
    _rulesSource = source;
    return _evaluator = PushruleEvaluator.fromRuleset(
      intentionalMentionsRuleset(source),
    );
  }
}

/// `m.push_rules.global` с раскрытыми `\.` в ключах условий (см. [LizaClient]).
PushRuleSet intentionalMentionsRuleset(Map<String, Object?>? pushRulesContent) {
  final global = pushRulesContent?['global'];
  if (global is! Map) return PushRuleSet();
  final copy = <String, Object?>{};
  for (final entry in global.entries) {
    final rules = entry.value;
    copy['${entry.key}'] = rules is List
        ? [for (final rule in rules) _unescapeRule(rule)]
        : rules;
  }
  try {
    return PushRuleSet.fromJson(copy);
  } catch (e, s) {
    Logs().v('Malformed PushRuleSet', e, s);
    return PushRuleSet();
  }
}

Object? _unescapeRule(Object? rule) {
  if (rule is! Map) return rule;
  final out = <String, Object?>{
    for (final e in rule.entries) '${e.key}': e.value,
  };
  final conditions = out['conditions'];
  if (conditions is List) {
    out['conditions'] = [
      for (final c in conditions)
        if (c is Map)
          <String, Object?>{
            for (final e in c.entries)
              '${e.key}': e.key == 'key' && e.value is String
                  ? (e.value as String).replaceAll(r'\.', '.')
                  : e.value,
          }
        else
          c,
    ];
  }
  return out;
}
