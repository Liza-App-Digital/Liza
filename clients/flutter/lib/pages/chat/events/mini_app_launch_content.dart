import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/miniapp_start_path.dart';
import 'package:liza/widgets/mxc_image.dart';
import 'package:liza/pages/chat/mini_app_registry.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';

/// Куда и как открыть mini App из launch-карточки.
class LaunchTarget {
  final String url;
  final String type;

  const LaunchTarget(this.url, this.type);
}

/// Адрес и тип для launch-карточки решает каталог, а не содержимое события.
///
/// Карточку может отправить любой участник чата. Если доверять её `app_url` и
/// `app_type`, то карточка `app_id: capsules` с чужим адресом получит initData
/// капсул (с почтой), а её можно обменять на вход. Поэтому:
/// - приложение есть в каталоге — его адрес и тип, поля события не важны;
/// - каталог загружен, но приложения в нём нет (личные приложения владельца) —
///   адрес из события, но только как стороннее, без initData во фрагменте;
/// - каталог не загрузился (`catalog == null`) — не открываем: отличить
///   подделку от своего приложения нечем.
LaunchTarget? resolveLaunchTarget({
  required String? appId,
  required String? eventUrl,
  required List<CatalogApp>? catalog,
}) {
  if (catalog == null) return null;
  for (final app in catalog) {
    if (app.appId == appId) {
      return Uri.tryParse(app.url)?.scheme == 'https'
          ? LaunchTarget(app.url, app.type)
          : null;
    }
  }
  if (eventUrl == null || Uri.tryParse(eventUrl)?.scheme != 'https') {
    return null;
  }
  return LaunchTarget(eventUrl, 'third_party');
}

/// Карточка запуска Mini App в чате.
///
/// Рендерит сообщение с `msgtype: "com.liza.miniapp.launch"` как карточку
/// с иконкой приложения, названием, опциональным превью и кнопкой запуска.
class MiniAppLaunchContent extends StatefulWidget {
  final Event event;
  final Color textColor;

  const MiniAppLaunchContent({
    required this.event,
    required this.textColor,
    super.key,
  });

  /// msgtype для launch-карточки Mini App.
  static const String msgType = 'com.liza.miniapp.launch';

  @override
  State<MiniAppLaunchContent> createState() => _MiniAppLaunchContentState();
}

class _MiniAppLaunchContentState extends State<MiniAppLaunchContent> {
  bool _loading = false;

  String get _appName {
    final name = widget.event.content.tryGet<String>('app_name');
    if (name != null && name.length <= 64) return name;
    return name?.substring(0, 64) ?? L10n.of(context).miniAppFallbackName;
  }

  String get _buttonText {
    final text = widget.event.content.tryGet<String>('button_text');
    if (text != null && text.length <= 32) return text;
    return text?.substring(0, 32) ?? L10n.of(context).chatInputOpen;
  }

  String? get _appUrl => widget.event.content.tryGet<String>('app_url');

  String? get _appId => widget.event.content.tryGet<String>('app_id');

  /// Deep-link на страницу mini App из launch-карточки (валидируем как границу).
  String get _appStartPath {
    final raw = widget.event.content.tryGet<String>('app_start_path');
    return (raw != null && isSafeStartPath(raw)) ? raw : '';
  }

  Uri? get _appIconMxc {
    final icon = widget.event.content.tryGet<String>('app_icon');
    return icon != null ? Uri.tryParse(icon) : null;
  }

  Uri? get _previewMxc {
    final preview = widget.event.content.tryGet<String>('app_preview');
    return preview != null ? Uri.tryParse(preview) : null;
  }

  /// Максимум картинок в карусели превью (остальное отсекаем на границе).
  static const int maxPreviews = 8;

  /// Список превью: `app_previews` (mxc-список) либо старое одиночное
  /// `app_preview`. Невалидные элементы отбрасываем.
  List<Uri> get _previews {
    final raw = widget.event.content.tryGetList<String>('app_previews');
    final uris = <Uri>[
      for (final s in raw ?? const <String>[])
        if (Uri.tryParse(s) case final u? when u.scheme == 'mxc') u,
    ];
    if (uris.isEmpty && _previewMxc != null) uris.add(_previewMxc!);
    return uris.take(maxPreviews).toList();
  }

  bool get _isValidUrl {
    final url = _appUrl;
    if (url == null) return false;
    final uri = Uri.tryParse(url);
    return uri != null && uri.scheme == 'https';
  }

  Future<void> _openMiniApp() async {
    if (!_isValidUrl || _loading) return;

    setState(() => _loading = true);

    try {
      List<CatalogApp>? catalog;
      try {
        catalog = await MiniAppRegistry.instance.fetch(
          widget.event.room.client,
        );
      } catch (e) {
        Logs().w('[MiniAppLaunch] каталог не загрузился: $e');
      }
      final target = resolveLaunchTarget(
        appId: _appId,
        eventUrl: _appUrl,
        catalog: catalog,
      );
      if (!mounted) return;
      if (target == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).miniAppLoadFailed)),
        );
        return;
      }
      await MiniAppWebView.open(
        context: context,
        appUrl: target.url,
        appId: _appId ?? 'unknown',
        appName: _appName,
        room: widget.event.room,
        appType: target.type,
        appStartPath: _appStartPath,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final previews = _previews;
    if (previews.isNotEmpty) {
      return Semantics(
        label: L10n.of(context).miniAppLaunchSemantics(_appName, _buttonText),
        button: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: MiniAppPreviewTile(
            event: widget.event,
            previews: previews,
            appName: _appName,
            loading: _loading,
            onOpen: _isValidUrl ? _openMiniApp : null,
          ),
        ),
      );
    }

    return Semantics(
      label: L10n.of(context).miniAppLaunchSemantics(_appName, _buttonText),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppConfig.borderRadius),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Превью изображение (опционально)
                if (_previewMxc != null)
                  ClipRRect(
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(AppConfig.borderRadius),
                      topRight: Radius.circular(AppConfig.borderRadius),
                    ),
                    child: AspectRatio(
                      aspectRatio: 2,
                      child: MxcImage(
                        uri: _previewMxc,
                        event: widget.event,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),

                // Иконка + название
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Row(
                    children: [
                      if (_appIconMxc != null) ...[
                        SizedBox(
                          width: 40,
                          height: 40,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: MxcImage(
                              uri: _appIconMxc,
                              event: widget.event,
                              fit: BoxFit.cover,
                              width: 40,
                              height: 40,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _appName,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: widget.textColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (widget.event.body.isNotEmpty &&
                                widget.event.body != _appName)
                              Text(
                                widget.event.body,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: widget.textColor.withAlpha(178),
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Кнопка "Открыть"
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: FilledButton(
                    onPressed: _isValidUrl ? _openMiniApp : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          AppConfig.borderRadius / 2,
                        ),
                      ),
                      minimumSize: const Size.fromHeight(44),
                    ),
                    child: _loading
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colorScheme.onPrimary,
                            ),
                          )
                        : Text(
                            _buttonText,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Превью mini App в ответе: квадрат со скруглёнными углами, ~90% —
/// карусель снимков, нижние ~10% — плашка с названием. Тап открывает
/// обычное окно mini App.
class MiniAppPreviewTile extends StatefulWidget {
  final Event event;
  final List<Uri> previews;
  final String appName;
  final bool loading;
  final VoidCallback? onOpen;

  const MiniAppPreviewTile({
    required this.event,
    required this.previews,
    required this.appName,
    required this.loading,
    required this.onOpen,
    super.key,
  });

  static const double size = 240;

  @override
  State<MiniAppPreviewTile> createState() => _MiniAppPreviewTileState();
}

class _MiniAppPreviewTileState extends State<MiniAppPreviewTile> {
  final _controller = PageController();
  int _index = 0;
  bool _hover = false;

  @override
  void didUpdateWidget(MiniAppPreviewTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.previews, widget.previews)) {
      _index = 0;
      if (_controller.hasClients) _controller.jumpToPage(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int delta) => _controller.animateToPage(
    _index + delta,
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppConfig.borderRadius);
    final count = widget.previews.length;

    Widget arrow(IconData icon, int delta) => Positioned(
      top: 0,
      bottom: 0,
      left: delta < 0 ? 6 : null,
      right: delta > 0 ? 6 : null,
      child: Center(
        child: Material(
          color: Colors.white.withAlpha(235),
          shape: const CircleBorder(),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _go(delta),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(icon, size: 20, color: Colors.black87),
            ),
          ),
        ),
      ),
    );

    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      heightFactor: 1,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: widget.onOpen != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        child: GestureDetector(
          onTap: widget.onOpen,
          child: SizedBox(
            width: MiniAppPreviewTile.size,
            height: MiniAppPreviewTile.size,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                color: scheme.surfaceContainerHigh,
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: Column(
                  children: [
                    Expanded(
                      flex: 9,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context).copyWith(
                              dragDevices: {
                                PointerDeviceKind.touch,
                                PointerDeviceKind.mouse,
                                PointerDeviceKind.trackpad,
                              },
                            ),
                            child: PageView.builder(
                              controller: _controller,
                              itemCount: count,
                              onPageChanged: (i) => setState(() => _index = i),
                              itemBuilder: (_, i) => MxcImage(
                                uri: widget.previews[i],
                                event: widget.event,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          if (count > 1) ...[
                            Positioned(
                              top: 8,
                              right: 8,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    '${_index + 1} / $count',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (_hover && _index > 0)
                              arrow(Icons.chevron_left, -1),
                            if (_hover && _index < count - 1)
                              arrow(Icons.chevron_right, 1),
                          ],
                        ],
                      ),
                    ),
                    Expanded(
                      child: ColoredBox(
                        color: scheme.surface,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.appName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              if (widget.loading)
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                Icon(
                                  Icons.chevron_right,
                                  size: 18,
                                  color: scheme.onSurfaceVariant,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
