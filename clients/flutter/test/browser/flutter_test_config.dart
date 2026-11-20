import 'dart:async';

// Только test/browser: native Alchemist comparator родительского config не
// компилируется с Flutter web. Golden-тестов в этом каталоге нет; стандартные
// Flutter test assertions/binding остаются. Общий host/golden config не меняем.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await testMain();
}
