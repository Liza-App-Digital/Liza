import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/resend_failed_media.dart';
import 'package:liza/utils/upload_progress_tracker.dart';

/// Состояние отправки поверх превью медиа: прогресс, «Ожидание сети» или ↻.
///
/// Общее для пузыря одиночного видео и плитки альбома (`compact`): раньше
/// оверлеи жили приватно в `video_player.dart`, и у плитки альбома статуса не
/// было вовсе — упавшее видео выглядело отправленным, а снекбар отсылал к
/// «значку повтора», которого не существовало (жалоба 2026-09-25).
///
/// Решение пересчитывается на каждое изменение владения серией
/// ([UploadProgressTracker.seriesChanges]): серия кончилась — упавшие члены
/// сразу рисуют ↻, не дожидаясь случайной перерисовки ленты.
///
/// [fallback] — что рисовать, когда отправка не идёт и не упала.
/// Размещение — забота вызывающего (`Positioned.fill` в `Stack`): оверлей
/// сам `Positioned` не несёт, чтобы его можно было обернуть (IgnorePointer).
class UploadStatusOverlay extends StatelessWidget {
  final Event event;
  final bool compact;
  final Widget fallback;

  const UploadStatusOverlay({
    required this.event,
    required this.fallback,
    this.compact = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final tracker = UploadProgressTracker.instance;
    return ValueListenableBuilder<int>(
      valueListenable: tracker.seriesChanges,
      builder: (context, _, _) {
        final id = event.eventId;
        final notifier = tracker.byId(id);
        // Упавший член идущей серии — не ошибка: серия дошлёт его сама,
        // пользователь видит прогресс/«Ожидание сети», а не ↻.
        if (event.status.isError && !tracker.isOwnedBySeries(id)) {
          return UploadRetryOverlay(event: event, compact: compact);
        }
        if (notifier != null) {
          return UploadProgressOverlay(
            notifier: notifier,
            event: event,
            compact: compact,
          );
        }
        return fallback;
      },
    );
  }
}

/// Полупрозрачный overlay поверх превью: кольцо прогресса вокруг тёмного
/// круга с крестиком (Liza-style). Тап по крестику отменяет загрузку.
/// Подписывается на [ValueNotifier] из [UploadProgressTracker] и
/// перерисовывает только индикатор — окружающий Stack не пересоздаётся.
class UploadProgressOverlay extends StatelessWidget {
  final ValueNotifier<double> notifier;
  final Event event;

  /// Плитка альбома (~88 px): кольцо меньше, подпись в одну строку.
  final bool compact;

  /// Только крестик, без кольца и подписи: превью ниже ~60 px (панорама
  /// рисуется высотой до 32 px) не вмещает даже compact-вариант.
  final bool buttonOnly;

  const UploadProgressOverlay({
    required this.notifier,
    required this.event,
    this.compact = false,
    this.buttonOnly = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final cancelLabel = L10n.of(context).cancel;
    final small = compact || buttonOnly;
    final ring = compact ? 40.0 : 64.0;
    final button = buttonOnly ? 24.0 : (compact ? 30.0 : 44.0);
    final cancelButton = Semantics(
      button: true,
      label: cancelLabel,
      child: Tooltip(
        message: cancelLabel,
        child: Material(
          type: MaterialType.circle,
          color: Colors.black54,
          child: InkWell(
            key: ValueKey('upload-cancel-${event.eventId}'),
            customBorder: const CircleBorder(),
            // ignore: discarded_futures
            onTap: () => cancelPendingSend(event),
            child: SizedBox(
              width: button,
              height: button,
              child: Icon(
                Icons.close,
                color: Colors.white,
                size: small ? 18 : 24,
              ),
            ),
          ),
        ),
      ),
    );
    if (buttonOnly) {
      return ColoredBox(
        color: Colors.black54,
        child: Center(child: cancelButton),
      );
    }
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: ring,
              height: ring,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ValueListenableBuilder<double>(
                    valueListenable: notifier,
                    builder: (context, value, _) => SizedBox(
                      width: ring,
                      height: ring,
                      child: CircularProgressIndicator(
                        value: value <= 0 ? null : value,
                        strokeWidth: compact ? 3 : 4,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation(Colors.white),
                      ),
                    ),
                  ),
                  cancelButton,
                ],
              ),
            ),
            SizedBox(height: compact ? 4 : 8),
            UploadPhaseLabel(
              event: event,
              notifier: notifier,
              compact: compact,
            ),
          ],
        ),
      ),
    );
  }
}

/// Подпись этапа отправки под кольцом прогресса.
///
/// Этап обязателен, а не украшение: шкала НЕ сквозная (у сжатия и у отдачи
/// свои 0..100), и без подписи переход «100%» → «3%» читается как «зависло и
/// откатилось». С подписью это «Сжатие 100%» → «Отправка 3%» — очевидная смена
/// этапа.
class UploadPhaseLabel extends StatelessWidget {
  final Event event;
  final ValueNotifier<double> notifier;
  final bool compact;

  const UploadPhaseLabel({
    required this.event,
    required this.notifier,
    this.compact = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final style = TextStyle(
      color: Colors.white,
      fontSize: compact ? 10 : 14,
      fontWeight: FontWeight.w600,
    );
    final phaseNotifier = UploadProgressTracker.instance.phaseFor(
      event.eventId,
    );

    Widget text(String data) => Text(
      data,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );

    Widget labelFor(UploadPhase phase) => ValueListenableBuilder<double>(
      valueListenable: notifier,
      builder: (context, value, _) {
        final name = switch (phase) {
          UploadPhase.preparing => l10n.uploadPhasePreparing,
          UploadPhase.compressing => l10n.uploadPhaseCompressing,
          UploadPhase.uploading => l10n.uploadPhaseUploading,
          UploadPhase.waitingNetwork => l10n.uploadWaitingForNetwork,
        };
        // В «Подготовке» и в «Ожидании сети» мерить нечего — кольцо крутится
        // неопределённым, процент не выдумываем.
        if (phase == UploadPhase.preparing ||
            phase == UploadPhase.waitingNetwork ||
            value <= 0) {
          return text(name);
        }
        return text('$name ~${(value * 100).round()}%');
      },
    );

    if (phaseNotifier == null) return labelFor(UploadPhase.uploading);
    return ValueListenableBuilder<UploadPhase>(
      valueListenable: phaseNotifier,
      builder: (context, phase, _) => labelFor(phase),
    );
  }
}

/// Overlay поверх превью медиа, когда отправка провалилась
/// (`EventStatus.error`) и серия отправки её больше не досылает. Тап по ↻ —
/// [FailedMediaResender]: гард потери байтов (LABA-2239 — иначе после
/// перезапуска приложения тап УДАЛЯЛ сообщение), анти-дабл-тап, сброс
/// устаревшего класса ошибки. Докачки в Matrix Media API нет — файл
/// перезаливается целиком. Авто-досыл при возврате связи —
/// `FailedSendRetryService`.
class UploadRetryOverlay extends StatelessWidget {
  final Event event;
  final bool compact;

  const UploadRetryOverlay({
    required this.event,
    this.compact = false,
    super.key,
  });

  void _retry(BuildContext context) {
    final outcome = FailedMediaResender.resend(event);
    if (outcome == ResendOutcome.missingMedia) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).fileNoLongerAvailableToResend)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final reason = UploadProgressTracker.instance.errorFor(event.eventId);
    final icon = CircleAvatar(
      radius: compact ? 16 : 20,
      backgroundColor: Colors.white24,
      child: Icon(Icons.refresh, color: Colors.white, size: compact ? 20 : 24),
    );
    return Semantics(
      button: true,
      label: l10n.tryToSendAgain,
      child: Tooltip(
        message: reason ?? l10n.tryToSendAgain,
        child: Material(
          color: Colors.black54,
          child: InkWell(
            key: ValueKey('upload-retry-${event.eventId}'),
            onTap: () => _retry(context),
            child: Center(
              child: compact
                  ? icon
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        icon,
                        const SizedBox(height: 8),
                        Text(
                          l10n.tryToSendAgain,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (reason != null) ...[
                          const SizedBox(height: 4),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              reason,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
