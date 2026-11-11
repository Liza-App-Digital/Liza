import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_window.dart';
import 'package:liza/utils/fluid_page.dart';
import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:liza/utils/platform_infos.dart';

/// Ширина превью: фиксированная — пузырь держит ширину по содержимому
/// (`IntrinsicWidth`), «сколько дадут» он не умеет.
const double kFluidPagePreviewWidth = 340;

/// Превью страниц, уже разобранных в этой сессии: лента перестраивает карточки
/// при прокрутке, качать и разбирать HTML каждый раз незачем.
final Map<String, Future<FluidPagePreview>> _previewCache = {};
const int _previewCacheMax = 32;

/// Зависшая загрузка не должна держать заглушку вечно: по таймауту карточка
/// показывает название и значок, страница по-прежнему открывается тапом.
const Duration _previewTimeout = Duration(seconds: 30);

/// Страница с фото весит сотни КБ: base64 и regex по ней на UI-изоляте дают
/// рывок ленты при появлении карточки. Мелкие документы разбираем на месте.
const int _parseInIsolateFrom = 64 * 1024;

Future<FluidPagePreview> _parsePreview(String html) =>
    html.length < _parseInIsolateFrom
    ? Future.value(parseFluidPagePreview(html))
    : compute(parseFluidPagePreview, html);

String _previewKey(Event event) => '${event.eventId}:${fluidPageSha256(event)}';

Future<FluidPagePreview> _previewFor(Event event) {
  final key = _previewKey(event);
  final cached = _previewCache.remove(key);
  if (cached != null) return _previewCache[key] = cached;
  if (_previewCache.length >= _previewCacheMax) {
    _previewCache.remove(_previewCache.keys.first);
  }
  final loader = FluidPageCard.debugLoadHtml ?? loadFluidPageHtml;
  final future = loader(event)
      .then(_parsePreview)
      .timeout(_previewTimeout)
      .catchError((Object e) {
        Logs().w('FluidPageCard: превью не собрано: $e');
        _previewCache.remove(key);
        return FluidPagePreview.empty;
      });
  return _previewCache[key] = future;
}

/// Виджет-превью HTML-страницы в ленте чата: фото страницы сеткой, название,
/// первый абзац и значок «открыть в окне». Тап — страница отдельным окном ОС
/// (пин-код или нет окон — панелью; на мобильном — листом). Сама страница без
/// клика не открывается.
class FluidPageCard extends StatefulWidget {
  final Event event;
  final Color textColor;

  const FluidPageCard({
    required this.event,
    required this.textColor,
    super.key,
  });

  /// Подмена загрузки HTML в widget-тестах.
  @visibleForTesting
  static Future<String> Function(Event event)? debugLoadHtml;

  @visibleForTesting
  static void debugClearCache() => _previewCache.clear();

  @override
  State<FluidPageCard> createState() => _FluidPageCardState();
}

class _FluidPageCardState extends State<FluidPageCard> {
  late Future<FluidPagePreview> _preview;

  /// Linux и Web: встроенного WebView нет — карточка открывает файл как
  /// обычное вложение.
  bool get _canEmbed => !PlatformInfos.isLinux && !PlatformInfos.isWeb;

  String get _title {
    final title = fluidPageTitle(widget.event);
    return title.isEmpty ? L10n.of(context).fluidPageOpen : title;
  }

  @override
  void initState() {
    super.initState();
    _preview = _previewFor(widget.event);
  }

  @override
  void didUpdateWidget(FluidPageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_previewKey(oldWidget.event) != _previewKey(widget.event)) {
      _preview = _previewFor(widget.event);
    }
  }

  void _open() {
    if (!_canEmbed) {
      widget.event.openFile(context);
      return;
    }
    MiniAppManager.instance.openPage(
      widget.event,
      title: _title,
      allowDetach: miniAppDetachAllowed(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = math.min(
      kFluidPagePreviewWidth,
      MediaQuery.sizeOf(context).width * 0.75,
    );
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('fluid-page-card'),
          onTap: _open,
          child: FutureBuilder<FluidPagePreview>(
            future: _preview,
            builder: (context, snapshot) {
              final preview = snapshot.data;
              final loading = snapshot.connectionState != ConnectionState.done;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (loading)
                    _PreviewPlaceholder(
                      height: width * 0.56,
                      color: widget.textColor,
                    )
                  else if (preview!.images.isNotEmpty)
                    _PreviewGrid(images: preview.images, width: width),
                  _Caption(
                    title: _title,
                    summary: preview?.summary ?? '',
                    textColor: widget.textColor,
                    showIcon: preview == null || preview.images.isEmpty,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Пока HTML качается — серая плашка высотой будущей сетки.
class _PreviewPlaceholder extends StatelessWidget {
  final double height;
  final Color color;

  const _PreviewPlaceholder({required this.height, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('fluid-page-preview-loading'),
    height: height,
    color: color.withAlpha(20),
    alignment: Alignment.center,
    child: SizedBox.square(
      dimension: 20,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    ),
  );
}

/// Сетка фото страницы: 1 — одно широкое, 2 — рядом, 3 — большое слева и два
/// справа, 4 — 2×2. В углу — значок «открыть в отдельном окне».
class _PreviewGrid extends StatelessWidget {
  final List<FluidPageImage> images;
  final double width;

  const _PreviewGrid({required this.images, required this.width});

  static const double _gap = 2;

  /// `SizedBox.expand`: в Row/Column поперечная ось свободна, и без него
  /// `BoxFit.cover` не заполняет ячейку — фото сжимается до своих пропорций.
  Widget _tile(BuildContext context, int i) => SizedBox.expand(
    key: ValueKey('fluid-page-preview-image-$i'),
    child: Image.memory(
      images[i].bytes,
      fit: BoxFit.cover,
      cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
      semanticLabel: images[i].alt.isEmpty ? null : images[i].alt,
      gaplessPlayback: true,
      errorBuilder: (context, _, _) => const ColoredBox(color: Colors.black12),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final height = width * (images.length == 1 ? 0.6 : 0.56);
    Widget column(List<int> idx) => Column(
      spacing: _gap,
      children: [for (final i in idx) Expanded(child: _tile(context, i))],
    );
    final grid = switch (images.length) {
      1 => _tile(context, 0),
      2 => Row(
        spacing: _gap,
        children: [
          Expanded(child: _tile(context, 0)),
          Expanded(child: _tile(context, 1)),
        ],
      ),
      3 => Row(
        spacing: _gap,
        children: [
          Expanded(flex: 2, child: _tile(context, 0)),
          Expanded(child: column([1, 2])),
        ],
      ),
      _ => Row(
        spacing: _gap,
        children: [
          Expanded(child: column([0, 2])),
          Expanded(child: column([1, 3])),
        ],
      ),
    };
    return SizedBox(
      key: const ValueKey('fluid-page-preview-grid'),
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          grid,
          Positioned(
            top: 8,
            right: 8,
            child: Tooltip(
              message: L10n.of(context).fluidPageOpen,
              child: Container(
                key: const ValueKey('fluid-page-open-icon'),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(140),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.open_in_new,
                  size: 18,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Название и первый абзац под сеткой. Без фото значок «открыть» стоит здесь.
class _Caption extends StatelessWidget {
  final String title;
  final String summary;
  final Color textColor;
  final bool showIcon;

  const _Caption({
    required this.title,
    required this.summary,
    required this.textColor,
    required this.showIcon,
  });

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
        ),
        if (summary.isNotEmpty)
          Text(
            summary,
            key: const ValueKey('fluid-page-preview-summary'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor.withAlpha(190), fontSize: 13),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Expanded(child: text),
          if (showIcon)
            Tooltip(
              message: L10n.of(context).fluidPageOpen,
              child: Icon(
                Icons.open_in_new,
                key: const ValueKey('fluid-page-open-icon'),
                size: 20,
                color: textColor.withAlpha(190),
              ),
            ),
        ],
      ),
    );
  }
}
