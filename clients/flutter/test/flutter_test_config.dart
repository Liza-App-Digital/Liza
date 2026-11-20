import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:liza/utils/unseen_messages.dart';

// Конфиг Alchemist для golden-тестов (Ярус 0, см. tests/e2e.md §4а).
// Применяется ко всем тестам в test/ автоматически (flutter_test_config.dart).
//
// Берём только CI-goldens: они рендерятся тест-шрифтом Ahem (каждый глиф —
// чёрный прямоугольник) и потому кроссплатформенно стабильны — эталон,
// снятый на macOS, совпадает с Linux-CI. platform-goldens (реальные шрифты
// по ОС) отключены: они хрупки к версии ОС/рендера и дают ложные падения.
Future<void> testExecutable(FutureOr<void> Function() testMain) {
  UnseenProjectionSubscription.initialHydration = false;
  return AlchemistConfig.runWithConfig(
    config: const AlchemistConfig(
      platformGoldensConfig: PlatformGoldensConfig(enabled: false),
    ),
    run: () async => testMain(),
  );
}
