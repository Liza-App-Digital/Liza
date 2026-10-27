/// Гейт первого кадра просмотрщика видео (заявка №52): пока libmpv не отдал
/// первый кадр, вместо чёрного `Video` с «паузой» и `0:00/0:00` пользователь
/// видит постер и индикатор загрузки.
///
/// Сигнал кадра — `width` из `video-out-params`, а НЕ
/// `VideoController.waitUntilFirstFrameRendered`: на Android его completer
/// одноразовый на контроллер и после свапа/«Повторить» сразу отдал бы ложное
/// «кадр есть». `Player.open` сам сбрасывает `width` в `null`.
///
/// `playing` в условии нет намеренно: сразу после `open` media_kit асинхронно
/// доставляет `pause=true→false`, и проверка `!playing` открыла бы гейт ложно.
/// Паузу передаёт её реальный источник — свайп карусели ([pausedByViewer]);
/// контролы во время гейта скрыты, руками поставить паузу нечем.
library;

/// Сколько держим гейт без кадра. Больше 15 с watchdog E2EE и 16 с
/// stalled-детектора: настоящий провал терминалят они, а по дедлайну мы лишь
/// показываем видео с контролами, как до гейта, — у ожидания всегда есть выход.
const Duration firstFrameGateDeadline = Duration(seconds: 20);

bool firstFrameGateOpen({
  required int? width,
  required Duration position,
  required bool pausedByViewer,
  required bool deadlinePassed,
}) {
  if ((width ?? 0) > 0) return true;
  // Дорожки видео нет (width не придёт никогда), но звук идёт.
  if (position > Duration.zero) return true;
  return pausedByViewer || deadlinePassed;
}
