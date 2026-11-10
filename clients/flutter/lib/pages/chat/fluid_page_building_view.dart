import 'dart:async';

import 'package:flutter/material.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/utils/fluid_page.dart';

/// Этапы, которые видит пользователь (done/failed — итог, не шаг).
const List<FluidPageStage> kFluidPageSteps = [
  FluidPageStage.answer,
  FluidPageStage.photos,
  FluidPageStage.layout,
];

String fluidPageStepLabel(L10n l10n, FluidPageStage stage) => switch (stage) {
  FluidPageStage.answer => l10n.fluidPageStageAnswer,
  FluidPageStage.photos => l10n.fluidPageStagePhotos,
  FluidPageStage.layout => l10n.fluidPageStageLayout,
  FluidPageStage.done => l10n.fluidPageReady,
  FluidPageStage.failed => l10n.fluidPageFailed,
};

/// «0:07», «1:42» — сколько идёт сборка.
String fluidPageElapsedLabel(Duration elapsed) {
  final s = elapsed.isNegative ? 0 : elapsed.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Перестраивает потомка раз в секунду, пока [running] (таймер сборки).
class _Ticker extends StatefulWidget {
  final bool running;
  final WidgetBuilder builder;

  const _Ticker({required this.running, required this.builder});

  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Ticker oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.running && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!widget.running) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// Список этапов: пройденные — галочка, текущий — крутилка, будущие — бледные.
class FluidPageSteps extends StatelessWidget {
  final FluidPageStage stage;
  final Color color;

  const FluidPageSteps({required this.stage, required this.color, super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final current = stage == FluidPageStage.done
        ? kFluidPageSteps.length
        : kFluidPageSteps.indexOf(stage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, step) in kFluidPageSteps.indexed)
          Padding(
            key: ValueKey('fluid-page-step-${step.name}'),
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                SizedBox.square(
                  dimension: 16,
                  child: i < current
                      ? Icon(Icons.check_circle, size: 16, color: color)
                      : i == current
                      ? CircularProgressIndicator(
                          key: const ValueKey('fluid-page-step-running'),
                          strokeWidth: 2,
                          color: color,
                        )
                      : Icon(
                          Icons.radio_button_unchecked,
                          size: 16,
                          color: color.withAlpha(90),
                        ),
                ),
                Flexible(
                  child: Text(
                    fluidPageStepLabel(l10n, step),
                    style: TextStyle(
                      color: i <= current ? color : color.withAlpha(110),
                      fontWeight: i == current
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Панель справа, пока бот собирает страницу: пульсирующий макет страницы,
/// этапы и время. Готовая страница встаёт на её место (MiniAppManager).
class FluidPageBuildingView extends StatelessWidget {
  final String pendingId;

  const FluidPageBuildingView({required this.pendingId, super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: ValueListenableBuilder<FluidPagePending?>(
        valueListenable: MiniAppManager.instance.pageBuild,
        builder: (context, pending, _) {
          if (pending == null || pending.id != pendingId) {
            return const SizedBox.shrink();
          }
          return _Ticker(
            running: !pending.finished,
            builder: (context) {
              final now = DateTime.now();
              final stage = pending.stageAt(now);
              if (stage == FluidPageStage.failed) {
                return Center(
                  key: const ValueKey('fluid-page-build-failed'),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      L10n.of(context).fluidPageFailed,
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return ListView(
                key: const ValueKey('fluid-page-building'),
                padding: const EdgeInsets.all(24),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          L10n.of(context).fluidPageBuilding,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      Text(
                        fluidPageElapsedLabel(now.difference(pending.started)),
                        key: const ValueKey('fluid-page-build-elapsed'),
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FluidPageSteps(stage: stage, color: scheme.primary),
                  const SizedBox(height: 24),
                  _SkeletonPage(color: scheme.surfaceContainerHighest),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Макет будущей страницы: заголовок, «фото», строки текста — пульсирует.
class _SkeletonPage extends StatefulWidget {
  final Color color;

  const _SkeletonPage({required this.color});

  @override
  State<_SkeletonPage> createState() => _SkeletonPageState();
}

class _SkeletonPageState extends State<_SkeletonPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    lowerBound: 0.45,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _block(double height, {double widthFactor = 1}) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => FadeTransition(
    key: const ValueKey('fluid-page-skeleton'),
    opacity: _pulse,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _block(26, widthFactor: 0.6),
        _block(14, widthFactor: 0.9),
        const SizedBox(height: 6),
        Row(
          spacing: 10,
          children: [
            Expanded(child: _block(110)),
            Expanded(child: _block(110)),
          ],
        ),
        _block(14),
        _block(14, widthFactor: 0.85),
        _block(14, widthFactor: 0.7),
        const SizedBox(height: 6),
        _block(60),
      ],
    ),
  );
}

/// Карточка обещания в ленте: этапы сборки с таймером, по итогу — «готова» или
/// «не получилось». Тап на широком окне — вернуть панель «собираю».
class FluidPageProgressCard extends StatelessWidget {
  final FluidPagePending pending;
  final Color textColor;
  final VoidCallback? onTap;

  const FluidPageProgressCard({
    required this.pending,
    required this.textColor,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return _Ticker(
      running: !pending.finished,
      builder: (context) {
        final now = DateTime.now();
        final stage = pending.stageAt(now);
        final Widget body;
        if (stage == FluidPageStage.done || stage == FluidPageStage.failed) {
          body = Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              Icon(
                stage == FluidPageStage.done
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                size: 18,
                color: textColor,
              ),
              Flexible(
                child: Text(
                  fluidPageStepLabel(l10n, stage),
                  style: TextStyle(color: textColor),
                ),
              ),
            ],
          );
        } else {
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  Flexible(
                    child: Text(
                      l10n.fluidPageBuilding,
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    fluidPageElapsedLabel(now.difference(pending.started)),
                    style: TextStyle(
                      color: textColor.withAlpha(170),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              FluidPageSteps(stage: stage, color: textColor),
            ],
          );
        }
        return InkWell(
          key: ValueKey('fluid-page-progress-${stage.name}'),
          onTap: stage.index < FluidPageStage.done.index ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: body,
            ),
          ),
        );
      },
    );
  }
}
