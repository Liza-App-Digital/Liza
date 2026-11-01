import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:matrix/matrix.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/widgets/mxc_image.dart';
import 'bot_interactive_content.dart';

/// Backend заменяется в host-тестах, сам lifecycle и дерево — продовые.
abstract class InlineVideoSession {
  Widget buildVideo();
  Future<void> open(Event event, {required bool loop, required bool muted});
  Future<void> dispose();
}

class _MediaKitSession implements InlineVideoSession {
  final _player = Player(configuration: const PlayerConfiguration(muted: true));
  late final _controller = VideoController(_player);
  bool _disposed = false;
  @override
  Widget buildVideo() => Video(
    controller: _controller,
    fit: BoxFit.cover,
    controls: NoVideoControls,
  );
  @override
  Future<void> open(
    Event event, {
    required bool loop,
    required bool muted,
  }) async {
    final uri = await event.getAttachmentUri().timeout(
      const Duration(seconds: 10),
    );
    if (_disposed) return;
    if (uri == null) throw StateError('No media');
    await _player.setVolume(muted ? 0 : 100);
    if (_disposed) return;
    await _player.setPlaylistMode(
      loop ? PlaylistMode.single : PlaylistMode.none,
    );
    if (_disposed) return;
    await _player.open(
      Media(
        uri.toString(),
        httpHeaders: {
          if (event.room.client.accessToken case final token?)
            'Authorization': 'Bearer $token',
        },
      ),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _player.dispose();
  }
}

/// Лента имеет максимум ОДИН активный inline Player, в том числе во время
/// открытия/закрытия. За пределами viewport и в фоне backend уничтожается.
/// Обычные видео продолжают использовать viewer и не попадают в этот бюджет.
class InlineBotVideo extends StatefulWidget {
  final Event event;
  final Widget poster;
  final bool autoplay;
  final bool loop;
  final bool round;
  final bool muted;
  final String label;
  final Widget? timeOverlay;
  final InlineVideoSession Function()? sessionFactory;
  const InlineBotVideo({
    required this.event,
    required this.poster,
    required this.label,
    this.autoplay = false,
    this.loop = false,
    this.round = false,
    this.muted = true,
    this.timeOverlay,
    this.sessionFactory,
    super.key,
  });
  @override
  State<InlineBotVideo> createState() => _InlineBotVideoState();
}

class _InlineBotVideoState extends State<InlineBotVideo>
    with WidgetsBindingObserver {
  static _InlineBotVideoState? _owner;
  final _visibilityKey = GlobalKey();
  Timer? _timer;
  InlineVideoSession? _session;
  bool _requested = false;
  bool _foreground = true;
  bool _enabled = true;
  bool _failed = false;
  bool _disposed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoplay) _monitor();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reconcile());
  }

  void _monitor() {
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _reconcile(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled = TickerMode.valuesOf(context).enabled;
    if (!_enabled) unawaited(_stop());
  }

  @override
  void didUpdateWidget(covariant InlineBotVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoplay) _monitor();
    if (oldWidget.event.eventId != widget.event.eventId ||
        oldWidget.event.content['url'] != widget.event.content['url'] ||
        oldWidget.event.room.id != widget.event.room.id ||
        oldWidget.event.room.client != widget.event.room.client) {
      _requested = false;
      _failed = false;
      unawaited(_stop());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _reconcile();
  }

  bool get _visible {
    final box = _visibilityKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    var visible = Offset.zero & MediaQuery.sizeOf(context);
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport is RenderBox) {
      final viewportBox = viewport as RenderBox;
      visible = visible.intersect(
        viewportBox.localToGlobal(Offset.zero) & viewportBox.size,
      );
    }
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final intersection = rect.intersect(visible);
    return intersection.width > 0 &&
        intersection.height > 0 &&
        intersection.width * intersection.height >=
            rect.width * rect.height * .5;
  }

  void _reconcile() {
    if (!mounted || _disposed) return;
    final eligible =
        _foreground &&
        _enabled &&
        _visible &&
        !_failed &&
        (widget.autoplay || _requested);
    if (!eligible) {
      if (!_foreground || !_visible) _requested = false;
      if (_session != null) unawaited(_stop());
      if (!widget.autoplay && !_requested) {
        _timer?.cancel();
        _timer = null;
      }
      return;
    }
    if (_owner == null && _session == null) unawaited(_start());
  }

  Future<void> _start() async {
    _owner = this;
    final generation = ++_generation;
    InlineVideoSession? session;
    try {
      session = widget.sessionFactory?.call() ?? _MediaKitSession();
      setState(() => _session = session);
      // Контроллер монтируется до открытия Media (mpv texture lifecycle).
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _disposed || generation != _generation) return;
      await session.open(widget.event, loop: widget.loop, muted: widget.muted);
      if (mounted && !_disposed && generation == _generation) setState(() {});
    } catch (_) {
      if (session == null && _owner == this) _owner = null;
      if (mounted && !_disposed && generation == _generation) {
        setState(() => _failed = true);
        unawaited(_stop());
      }
    }
  }

  Future<void> _stop() async {
    final session = _session;
    if (session == null) return;
    ++_generation;
    _session = null;
    if (mounted && !_disposed) setState(() {});
    // Backend блокирует позднее открытие после dispose, в том числе пока
    // вычисляется URI. На всё время cleanup lease сохраняется.
    try {
      await session.dispose();
    } catch (error, stack) {
      Logs().w('Inline video dispose failed', error, stack);
    } finally {
      if (_owner == this) _owner = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = SizedBox(
      key: _visibilityKey,
      width: widget.round ? 240 : 280,
      height: widget.round ? 240 : 280,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.poster,
          if (_session case final session?) session.buildVideo(),
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  if (_session != null) {
                    _requested = false;
                    _failed = true; // Явная пауза действует до следующего тапа.
                    unawaited(_stop());
                  } else {
                    final owner = _owner;
                    if (owner != null && owner != this) {
                      owner._requested = false;
                      owner._failed = true;
                      unawaited(owner._stop());
                    }
                    _failed = false;
                    _requested = true;
                    _monitor();
                    _reconcile();
                  }
                },
                child: Center(
                  child: CircleAvatar(
                    backgroundColor: Colors.black54,
                    child: Icon(
                      _session == null ? Icons.play_arrow : Icons.pause,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: widget.round ? 30 : 8,
            left: widget.round ? 50 : 8,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.all(4),
              child: Text(
                widget.label,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
          if (_failed && _session == null)
            const Positioned(
              right: 14,
              top: 14,
              child: Icon(Icons.refresh, color: Colors.white),
            ),
          if (widget.timeOverlay case final time?)
            Positioned(
              bottom: widget.round ? 28 : 8,
              right: widget.round ? 42 : 8,
              child: time,
            ),
        ],
      ),
    );
    return Semantics(
      label: widget.label,
      child: widget.round
          ? ClipOval(child: media)
          : ClipRRect(borderRadius: BorderRadius.circular(12), child: media),
    );
  }
}

/// Flutter Image при TickerMode(false) снимает animation stream listener.
/// Сохраняем исходный Image/cache и пользовательский autoplay preference,
/// останавливая GIF вне viewport, при закрытии route и в фоне приложения.
class ViewportAnimation extends StatefulWidget {
  final Widget child;
  const ViewportAnimation({required this.child, super.key});
  @override
  State<ViewportAnimation> createState() => _ViewportAnimationState();
}

class _ViewportAnimationState extends State<ViewportAnimation>
    with WidgetsBindingObserver {
  final _key = GlobalKey();
  Timer? _timer;
  bool _visible = false;
  bool _foreground = true;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) => _check());
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (!mounted || _disposed) return;
    final box = _key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    var viewportRect = Offset.zero & MediaQuery.sizeOf(context);
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport is RenderBox) {
      final viewportBox = viewport as RenderBox;
      viewportRect = viewportRect.intersect(
        viewportBox.localToGlobal(Offset.zero) & viewportBox.size,
      );
    }
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final next = _foreground && rect.overlaps(viewportRect);
    if (next != _visible) setState(() => _visible = next);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _check();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TickerMode(
    enabled: _visible && TickerMode.valuesOf(context).enabled,
    child: SizedBox(key: _key, child: widget.child),
  );
}

class BotLivePhotoContent extends StatelessWidget {
  final Event event;
  final BotLivePhoto photo;
  final Widget? timeOverlay;
  const BotLivePhotoContent({
    required this.event,
    required this.photo,
    this.timeOverlay,
    super.key,
  });
  @override
  Widget build(BuildContext context) => InlineBotVideo(
    event: event,
    label: L10n.of(context).botLivePhoto,
    loop: true,
    timeOverlay: timeOverlay,
    poster: MxcImage(
      uri: photo.cover,
      client: event.room.client,
      isThumbnail: false,
      fit: BoxFit.cover,
    ),
  );
}
