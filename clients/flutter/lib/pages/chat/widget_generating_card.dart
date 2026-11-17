import 'dart:async';

import 'package:flutter/material.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/widget_progress.dart';
import 'package:liza/widgets/avatar.dart';

/// Карточка-загрузка вместо typing: Лиза собирает виджет.
///
/// Не сообщение и не интерактивный элемент: живёт только пока в комнате есть
/// свежий прогресс. Проценты приходят с сервера монотонно, здесь только
/// анимация к новому значению и вращающаяся шутливая строка.
class WidgetGeneratingCard extends StatefulWidget {
  final WidgetGenerationProgress progress;

  const WidgetGeneratingCard({required this.progress, super.key});

  @override
  State<WidgetGeneratingCard> createState() => _WidgetGeneratingCardState();
}

class _WidgetGeneratingCardState extends State<WidgetGeneratingCard> {
  static const Duration _hintEvery = Duration(seconds: 3);
  late final Timer _timer;
  int _hint = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_hintEvery, (_) {
      if (!mounted) return;
      setState(() => _hint++);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  List<String> _hints(L10n l10n) => [
    l10n.widgetGeneratingHint1,
    l10n.widgetGeneratingHint2,
    l10n.widgetGeneratingHint3,
    l10n.widgetGeneratingHint4,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final progress = widget.progress;
    final stageLabel = progress.stage == 'sending'
        ? l10n.widgetGeneratingSending
        : l10n.widgetGeneratingWriting;
    final hints = _hints(l10n);
    final hint = hints[_hint % hints.length];
    final percent = progress.percent.clamp(0, 100);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Material(
        key: const ValueKey('widget-generating-card'),
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.all(
          Radius.circular(AppConfig.borderRadius),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        stageLabel,
                        key: ValueKey(stageLabel),
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$percent%',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: percent / 100),
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOut,
                  builder: (context, value, _) => LinearProgressIndicator(
                    key: const ValueKey('widget-generating-progress'),
                    value: value,
                    minHeight: 4,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                child: Text(
                  hint,
                  key: ValueKey(hint),
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Строка в слоте typing: аватар ассистента + карточка-загрузка.
class WidgetGeneratingRow extends StatelessWidget {
  final Uri? avatarUrl;
  final String name;
  final bool isAi;
  final WidgetGenerationProgress progress;

  const WidgetGeneratingRow({
    required this.avatarUrl,
    required this.name,
    required this.isAi,
    required this.progress,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    const avatarSize = Avatar.defaultSize / 2;
    return Container(
      key: const ValueKey('widget-generating-row'),
      width: double.infinity,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: LizaThemes.maxTimelineWidth,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: Avatar.defaultSize,
              child: Center(
                child: Avatar(
                  size: avatarSize,
                  mxContent: avatarUrl,
                  name: name,
                  isHexagonal: isAi,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(child: WidgetGeneratingCard(progress: progress)),
          ],
        ),
      ),
    );
  }
}
