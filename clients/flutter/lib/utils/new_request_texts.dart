import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/app_config.dart';

/// Тексты страницы «Новый запрос», которые правятся без выпуска сборки:
/// плашки-пресеты и бегущая строка примеров.
@immutable
class NewRequestContent {
  const NewRequestContent({required this.presets, required this.examples});

  final List<String> presets;
  final List<String> examples;
}

const int _maxPresets = 5;
const int _maxPresetLength = 80;
const int _maxExamples = 10;
const int _maxExampleLength = 140;

List<String> _cleanList(Object? raw, int maxItems, int maxLength) {
  if (raw is! List) return const [];
  final seen = <String>{};
  final out = <String>[];
  for (final item in raw) {
    if (item is! String) continue;
    final line = item.trim();
    if (line.isEmpty || line.runes.length > maxLength) continue;
    if (!seen.add(line.toLowerCase())) continue;
    out.add(line);
    if (out.length == maxItems) break;
  }
  return out;
}

/// Разбор ответа `/liza/v1/new-request-content`. Сервер уже чистит ввод, но
/// клиент не доверяет: кривой JSON, не-ru или пустые списки → `null` (панель
/// остаётся на текстах из ARB). Один из списков пуст — берём только второй.
NewRequestContent? parseNewRequestContent(Object? json) {
  if (json is! Map) return null;
  final ru = json['ru'];
  if (ru is! Map) return null;
  final presets = _cleanList(ru['presets'], _maxPresets, _maxPresetLength);
  final examples = _cleanList(ru['examples'], _maxExamples, _maxExampleLength);
  if (presets.isEmpty && examples.isEmpty) return null;
  return NewRequestContent(presets: presets, examples: examples);
}

/// Серверные тексты «Нового запроса»: кэш в SharedPreferences читается до
/// первого кадра, свежая версия подтягивается в фоне и применяется при
/// СЛЕДУЮЩЕМ открытии панели — на экране тексты не меняются и бегущая строка
/// не перезапускается.
class NewRequestTexts {
  NewRequestTexts._();

  static final NewRequestTexts instance = NewRequestTexts._();

  static const String _prefsKey = 'liza.new_request_content';

  /// Применённая версия: её видит открывающаяся панель.
  NewRequestContent? current;

  NewRequestContent? _fetched;
  bool _loaded = false;
  bool _inFlight = false;

  /// Читает кэш с диска (один раз за запуск).
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
      if (raw != null) current = parseNewRequestContent(jsonDecode(raw));
    } catch (e) {
      Logs().v('[NewRequestTexts] cache read failed: $e');
    }
  }

  /// Переносит скачанное в фоне в `current`. Вызывается при открытии панели.
  void applyFetched() {
    final fetched = _fetched;
    if (fetched != null) {
      current = fetched;
      _fetched = null;
    }
  }

  /// Фоновая загрузка: сеть/сервер недоступны → молча остаёмся на кэше.
  Future<void> refresh(String? homeserverHost) async {
    if (_inFlight || homeserverHost == null || homeserverHost.isEmpty) return;
    _inFlight = true;
    try {
      final base = AppConfig.lizaBotApiBaseForHomeserver(homeserverHost);
      final resp = await http
          .get(Uri.parse('$base/liza/v1/new-request-content'))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return;
      final body = utf8.decode(resp.bodyBytes);
      final parsed = parseNewRequestContent(jsonDecode(body));
      final prefs = await SharedPreferences.getInstance();
      if (parsed == null) {
        // Сервер отдал пусто (reset) — кэш тоже сбрасываем, иначе «reset»
        // у клиента не сработает никогда.
        await prefs.remove(_prefsKey);
        _fetched = null;
        current = null;
        return;
      }
      await prefs.setString(_prefsKey, body);
      _fetched = parsed;
    } catch (e) {
      Logs().v('[NewRequestTexts] refresh failed: $e');
    } finally {
      _inFlight = false;
    }
  }
}
