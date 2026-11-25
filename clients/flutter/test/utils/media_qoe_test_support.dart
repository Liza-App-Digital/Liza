import 'package:liza/utils/media_qoe_session.dart';

/// Приёмник маяка для тестов: копит opened/finished/dropped по порядку.
class RecordingSink implements MediaQoeSink {
  final opens = <Map<String, Object>>[];
  final finishes = <Map<String, Object>>[];
  final drops = <String>[];

  @override
  void opened(Map<String, Object> event) => opens.add(event);

  @override
  void finished(Map<String, Object> event) => finishes.add(event);

  @override
  void dropped(String attemptId) => drops.add(attemptId);
}

/// Приёмник, который падает на каждом вызове (AC-7: ошибка маяка не
/// доходит до плеера и отправки).
class ThrowingSink implements MediaQoeSink {
  @override
  void opened(Map<String, Object> event) => throw StateError('sink');

  @override
  void finished(Map<String, Object> event) => throw StateError('sink');

  @override
  void dropped(String attemptId) => throw StateError('sink');
}

/// Управляемые часы сессии: `elapsedMilliseconds` задаёт тест.
class FakeStopwatch implements Stopwatch {
  int ms = 0;

  @override
  int get elapsedMilliseconds => ms;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
