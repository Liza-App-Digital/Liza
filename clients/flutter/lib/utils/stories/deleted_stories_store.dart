import 'package:shared_preferences/shared_preferences.dart';

/// Локальный список сторис, которые автор удалил С ЭТОГО устройства (LABA-2618).
///
/// Удалённая сторис отсекается фильтром и тогда, когда редакция по какой-то
/// причине не применилась к копии в локальной БД SDK (07.09 на Web она
/// «оживала» при каждом открытии вьюера, а автор слал PUT redact снова и
/// снова). Корень не установлен — поэтому срабатывание фильтра по этому
/// списку репортится датчиком `[stories-resurrected]`, а не глушится молча.
///
/// prefs, а не память процесса: список переживает перезапуск приложения и
/// перезагрузку страницы (на Web — localStorage). [scope] (userID) изолирует
/// аккаунты.
class DeletedStoriesStore {
  final SharedPreferences _prefs;
  final String _key;
  final int Function() _now;

  /// Сторис живёт 24 ч; запас на рассинхрон часов — как cutoff в
  /// activeStoriesWithTimeline. Старше — сторис отсекает TTL, запись не нужна.
  static const int ttlMs = 25 * 3600 * 1000;

  DeletedStoriesStore(this._prefs, {String? scope, int Function()? now})
    : _key = 'com.liza.stories.deleted.${scope ?? ''}',
      _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  Map<String, int> _read() {
    final cutoff = _now() - ttlMs;
    final result = <String, int>{};
    for (final entry in _prefs.getStringList(_key) ?? const <String>[]) {
      final sep = entry.lastIndexOf('|');
      if (sep <= 0) continue;
      final ts = int.tryParse(entry.substring(sep + 1));
      if (ts == null || ts < cutoff) continue;
      result[entry.substring(0, sep)] = ts;
    }
    return result;
  }

  /// Без своего кеша: экземпляров несколько (вьюер, лента, карточка-ссылка)
  /// поверх одного SharedPreferences — запись одного сразу видна остальным.
  /// Список крошечный, чтение prefs синхронное.
  Set<String> get ids => _read().keys.toSet();

  bool contains(String eventId) => _read().containsKey(eventId);

  /// Удалённые раньше [settleMs] назад. Сразу после PUT редакция ещё не
  /// доехала по sync, и нередактированная локальная копия — норма, а не
  /// «воскрешение»: датчик смотрит только на эти id.
  static const int settleMs = 60 * 1000;

  Set<String> get settledIds {
    final before = _now() - settleMs;
    return {
      for (final e in _read().entries)
        if (e.value <= before) e.key,
    };
  }

  Future<void> add(String eventId) async {
    final entries = _read()..[eventId] = _now();
    await _prefs.setStringList(_key, [
      for (final e in entries.entries) '${e.key}|${e.value}',
    ]);
  }
}
