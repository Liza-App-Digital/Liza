// ledger:RL-read-receipt-viewport-based
//
// LABA-2632: до конца позиционирования при открытии чата `_sendReadMarkerNow`
// обязан молчать — иначе `updateView` от `requestHistory` (>30 непрочитанных)
// шлёт ПОЛНУЮ квитанцию с ещё смонтированного низа. Поведенческий страж —
// device-flow `integration_test/liza/open_chat_many_unread_flow_test.dart`
// (AC-13, оракул — сервер); здесь — порядок гейта и снятие флага на всех
// выходах, которые device-flow не перебирает.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Тело метода от [opener] (оканчивается на `{`) до парной `}`; комментарии
/// вырезаны — в них упоминаются запрещённые формы вызова.
String _body(String src, String opener) {
  final start = src.indexOf(opener);
  if (start < 0) throw StateError('нет $opener');
  var depth = 0;
  for (var i = start + opener.length - 1; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}' && --depth == 0) {
      return src
          .substring(start + opener.length, i + 1)
          .replaceAll(RegExp(r'//[^\n]*'), '');
    }
  }
  throw StateError('не закрыт $opener');
}

void main() {
  final chat = File('lib/pages/chat/chat.dart').readAsStringSync();
  final send = _body(
    chat,
    'Future<void>? _sendReadMarkerNow({String? eventId, bool force = false}) {',
  );
  final load = _body(chat, 'void _tryLoadTimeline() async {');

  test(
    'AC:RL-read-receipt-viewport-based/14 гейт позиционирования — первая '
    'проверка _sendReadMarkerNow, до force/lifecycle/оптимистичной аватарки',
    () {
      // Ветка гейта пишет причину в лог (заявка №60) — проверяем сам гейт,
      // а не однострочную форму `return null`.
      final gate = send.indexOf('if (_openPositioningPending) {');
      expect(gate, greaterThanOrEqualTo(0));
      for (final later in [
        '_scrolledUp',
        'force',
        'readableForeground(',
        'recordOwnReadMarkerTs(',
        'timeline.setReadMarker(',
        'timeline\n        .setReadMarker(',
      ]) {
        final at = send.indexOf(later);
        if (later.startsWith('timeline') && at < 0) continue;
        expect(at, greaterThan(gate), reason: '$later раньше гейта');
      }
    },
  );

  test('AC:RL-read-receipt-viewport-based/15 флаг поднят до _getTimeline и '
      'снимается в finally и перед финальными квитанциями плана', () {
    final raise = load.indexOf('_openPositioningPending = true;');
    expect(raise, greaterThanOrEqualTo(0));
    expect(raise, lessThan(load.indexOf('_getTimeline()')));

    final fin = load.lastIndexOf('} finally {');
    expect(fin, greaterThan(0), reason: 'нет finally-backstop');
    expect(
      load.indexOf('_openPositioningPending = false;', fin),
      greaterThan(fin),
    );

    // Каждый финальный setReadMarker плана — после снятия флага.
    // Ближайшее ПРЕДШЕСТВУЮЩЕЕ присваивание флага — именно снятие.
    for (final call in RegExp(r'\bsetReadMarker\(').allMatches(load)) {
      final before = load.substring(0, call.start);
      expect(
        before.lastIndexOf('_openPositioningPending = false;'),
        greaterThan(before.lastIndexOf('_openPositioningPending = true;')),
        reason:
            'setReadMarker на ${call.start} до снятия флага — будет '
            'проглочен, квитанция при открытии не уйдёт (LABA-1894)',
      );
    }
  });

  test('AC:RL-read-receipt-viewport-based/16 после позиционирования на '
      'сепараторе — только явная частичная квитанция', () {
    final branch = load.substring(
      load.indexOf('if (plan.scrollToDivider)'),
      load.indexOf('if (plan.markLastEvent)'),
    );
    expect(branch, contains('_newestVisibleEventId()'));
    expect(branch, contains('setReadMarker(eventId: visibleEventId)'));
    expect(
      RegExp(r'setReadMarker\(\)').hasMatch(
        branch.substring(0, branch.indexOf('_showScrollUpMaterialBanner')),
      ),
      isFalse,
      reason: 'голый setReadMarker() при неудавшемся позиционировании = full',
    );
  });

  test('AC:RL-read-receipt-viewport-based/19 ветка открытия на сепараторе: '
      'scrollToEventId → доводка отсечки по строке-anchor → только потом '
      'снятие гейта', () {
    final branch = load.substring(
      load.indexOf('if (plan.scrollToDivider)'),
      load.indexOf('if (plan.markLastEvent)'),
    );
    final scroll = branch.indexOf('scrollToEventId(readMarkerEventId');
    final align = branch.indexOf('alignRowBottomToDivider(');
    final release = branch.indexOf('_openPositioningPending = false;');
    expect(scroll, greaterThanOrEqualTo(0));
    expect(align, greaterThan(scroll));
    expect(
      release,
      greaterThan(align),
      reason:
          'jumpTo после снятия гейта '
          'запустит дебаунс квитанции по промежуточной геометрии',
    );
    expect(branch, contains('_rowIdOf(readMarkerEventId)'));
  });

  test('AC:RL-read-receipt-viewport-based/21 scrollToEventId крутит к строке '
      'самой цели (scrollTargetIndex), без унаследованного +1', () {
    final body = _body(
      chat,
      'Future<void> scrollToEventId(\n'
      '    String eventId, {\n'
      '    bool highlightEvent = true,\n'
      '    int retryDepth = 0,\n'
      '  }) async {',
    );
    expect(body, contains('scrollTargetIndex('));
    expect(body, isNot(contains('eventIndex + 1')));
    expect(body, contains('scrollToEventIdMarker = _rowIdOf(eventId)'));
  });
}
