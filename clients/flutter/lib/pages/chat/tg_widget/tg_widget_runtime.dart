import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'package:liza/pages/chat/tg_widget/tg_widget_api.dart';
import 'package:liza/utils/platform_infos.dart';

/// Слот экземпляра виджета в бюджете.
enum TgWidgetSlot {
  /// Экземпляра нет (постер).
  none,

  /// Живой и на экране: `activated`, `document.hidden == false`.
  active,

  /// Ушёл с экрана, но WebView ещё жив: `deactivated`, таймеры редки. Его
  /// уничтожают, только когда слот нужен видимому виджету или по таймауту.
  parked,
}

/// Бюджет живых экземпляров (D9): ≤2 WebView на телефоне, ≤3 на десктопе,
/// считая и «запаркованные». Право быть активным даёт ВИДИМОСТЬ на экране, а
/// не жизнь строки ленты: keep-alive строка за экраном максимум паркуется.
class TgWidgetLiveBudget with WidgetsBindingObserver {
  final int capacity;

  TgWidgetLiveBudget({required this.capacity});

  static int get platformCapacity => PlatformInfos.isMobile ? 2 : 3;

  /// Сколько держим запаркованный экземпляр, если слот никому не нужен.
  static const Duration parkTimeout = Duration(seconds: 30);

  static TgWidgetLiveBudget? _instance;
  static TgWidgetLiveBudget get instance =>
      _instance ??= TgWidgetLiveBudget(capacity: platformCapacity)
        .._observeLifecycle();

  /// Шов для тестов: свой бюджет (ёмкость «телефон»/«десктоп»).
  static set debugInstance(TgWidgetLiveBudget? value) {
    _instance?._dispose();
    _instance = value;
  }

  final LinkedHashMap<Object, _Candidate> _candidates = LinkedHashMap();
  final Map<Object, TgWidgetSlot> _slots = {};

  /// Когда экземпляр последний раз был активным — кого выселять первым.
  final Map<Object, int> _lastActive = {};
  int _clock = 0;
  bool _appActive = true;
  bool _scheduled = false;
  bool _observing = false;

  void _observeLifecycle() {
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
  }

  void _dispose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
  }

  /// Живых экземпляров (WebView), активных и запаркованных.
  int get liveCount => _slots.length;

  int get activeCount =>
      _slots.values.where((s) => s == TgWidgetSlot.active).length;

  TgWidgetSlot slotOf(Object key) => _slots[key] ?? TgWidgetSlot.none;

  /// [fraction] — видимая доля пузыря (0 — за экраном). [wantsLive] — виджет
  /// готов жить (подпись проверена, «Запустить» нажат, не остановлен).
  void update(
    Object key, {
    required double fraction,
    required bool wantsLive,
    required ValueChanged<TgWidgetSlot> onChanged,
  }) {
    final c = _candidates[key];
    if (c != null &&
        c.fraction == fraction &&
        c.wantsLive == wantsLive &&
        identical(c.onChanged, onChanged)) {
      return;
    }
    final expired = (c?.expired ?? false) && fraction <= 0;
    _candidates[key] = _Candidate(fraction, wantsLive, onChanged, expired);
    _schedule();
  }

  /// Таймаут парковки истёк: экземпляр отдаём, пока виджет снова не покажется.
  void expire(Object key) {
    final c = _candidates[key];
    if (c == null || c.fraction > 0) return;
    c.expired = true;
    _schedule();
  }

  /// Без уведомления: элемент сам уже освободил экземпляр (dispose/deactivate).
  void remove(Object key) {
    _candidates.remove(key);
    _lastActive.remove(key);
    if (_slots.remove(key) != null) _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == _appActive) return;
    _appActive = active;
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      recompute();
    });
  }

  /// Активны самые видимые (при равенстве — уже живые, без дребезга).
  /// Оставшуюся ёмкость занимают запаркованные — недавно активные первыми.
  @visibleForTesting
  void recompute() {
    final visible =
        _candidates.entries
            .where(
              (e) => _appActive && e.value.wantsLive && e.value.fraction > 0,
            )
            .toList()
          ..sort((a, b) {
            final byFraction = b.value.fraction.compareTo(a.value.fraction);
            if (byFraction != 0) return byFraction;
            final aLive = _slots.containsKey(a.key) ? 0 : 1;
            final bLive = _slots.containsKey(b.key) ? 0 : 1;
            return aLive.compareTo(bLive);
          });
    final next = <Object, TgWidgetSlot>{
      for (final e in visible.take(capacity)) e.key: TgWidgetSlot.active,
    };
    final parkable =
        _slots.keys
            .where(
              (k) =>
                  !next.containsKey(k) &&
                  (_candidates[k]?.wantsLive ?? false) &&
                  !(_candidates[k]?.expired ?? true),
            )
            .toList()
          ..sort(
            (a, b) => (_lastActive[b] ?? 0).compareTo(_lastActive[a] ?? 0),
          );
    for (final k in parkable) {
      if (next.length >= capacity) break;
      next[k] = TgWidgetSlot.parked;
    }
    final changed = <Object, TgWidgetSlot>{};
    for (final k in {..._slots.keys, ...next.keys}) {
      final before = _slots[k] ?? TgWidgetSlot.none;
      final after = next[k] ?? TgWidgetSlot.none;
      if (before != after) changed[k] = after;
    }
    _slots
      ..clear()
      ..addAll(next);
    _clock++;
    for (final e in next.entries) {
      if (e.value == TgWidgetSlot.active) _lastActive[e.key] = _clock;
    }
    // Сначала освобождаем, потом выдаём: WebView больше ёмкости не бывает.
    for (final e in changed.entries.where(
      (e) => e.value == TgWidgetSlot.none,
    )) {
      _candidates[e.key]?.onChanged(TgWidgetSlot.none);
    }
    for (final e in changed.entries.where(
      (e) => e.value != TgWidgetSlot.none,
    )) {
      _candidates[e.key]?.onChanged(e.value);
    }
  }
}

class _Candidate {
  final double fraction;
  final bool wantsLive;
  final ValueChanged<TgWidgetSlot> onChanged;
  bool expired;

  _Candidate(this.fraction, this.wantsLive, this.onChanged, this.expired);
}

/// Видимая доля [context] во вьюпорте ленты. Строка, которую SliverList держит
/// keep-alive за экраном (`keptAlive`), и скрытый маршрут (`TickerMode`) —
/// невидимы, даже если их render-объект ещё прикреплён.
double tgWidgetVisibleFraction(BuildContext context) {
  if (!TickerMode.valuesOf(context).enabled) return 0;
  final ro = context.findRenderObject();
  if (ro is! RenderBox || !ro.attached || !ro.hasSize || ro.size.isEmpty) {
    return 0;
  }
  RenderObject? node = ro;
  while (node != null) {
    final pd = node.parentData;
    if (pd is SliverMultiBoxAdaptorParentData && pd.keptAlive) return 0;
    node = node.parent;
  }
  final rect = MatrixUtils.transformRect(
    ro.getTransformTo(null),
    Offset.zero & ro.size,
  );
  final RenderObject? viewport = RenderAbstractViewport.maybeOf(ro);
  Rect clip;
  if (viewport is RenderBox && viewport.hasSize) {
    clip = MatrixUtils.transformRect(
      viewport.getTransformTo(null),
      Offset.zero & viewport.size,
    );
  } else {
    final view = View.maybeOf(context);
    if (view == null) return 0;
    clip = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  }
  final inter = rect.intersect(clip);
  if (inter.width <= 0 || inter.height <= 0) return 0;
  return (inter.width * inter.height) / (rect.width * rect.height);
}

/// Постеры: последний кадр живого виджета, ключ — событие + хэш состояния
/// (старый снимок при новом `chat_data` показывал бы прошлое состояние).
abstract final class TgWidgetPosters {
  static const int maxEntries = 48;
  static final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();

  static String key(String eventId, String? chatData, String? publicData) =>
      '$eventId#${Object.hash(chatData, publicData)}';

  static Uint8List? get(String key) {
    final hit = _cache.remove(key);
    if (hit != null) _cache[key] = hit;
    return hit;
  }

  static void put(String key, Uint8List png) {
    _cache.remove(key);
    _cache[key] = png;
    while (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  static void debugClear() => _cache.clear();
}

/// Один опрос `public_data` на `widget_id` (не на пузырь), раз в
/// `cache_time`, пока есть хоть один видимый наблюдатель (D3).
class TgSharedWidgetPoller {
  TgSharedWidgetPoller._();
  static final TgSharedWidgetPoller instance = TgSharedWidgetPoller._();

  final Map<String, _Poll> _polls = {};

  /// Возвращает функцию отписки.
  VoidCallback watch(
    TgWidgetApi api,
    String widgetId,
    ValueChanged<String?> onData,
  ) {
    final key = '${api.base}|$widgetId';
    final poll = _polls[key] ??= _Poll(api, widgetId);
    poll.listeners.add(onData);
    if (poll.listeners.length == 1) poll.start();
    return () {
      poll.listeners.remove(onData);
      if (poll.listeners.isEmpty) {
        poll.stop();
        _polls.remove(key);
      }
    };
  }

  @visibleForTesting
  int get activePolls => _polls.length;

  void debugReset() {
    for (final p in _polls.values) {
      p.stop();
    }
    _polls.clear();
  }
}

class _Poll {
  final TgWidgetApi api;
  final String widgetId;
  final List<ValueChanged<String?>> listeners = [];
  Timer? _timer;
  String? _etag;
  String? _data;
  bool _hasData = false;
  bool _running = false;

  _Poll(this.api, this.widgetId);

  void start() {
    _running = true;
    unawaited(_tick());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
  }

  Future<void> _tick() async {
    if (!_running) return;
    final state = await api.sharedWidget(widgetId, etag: _etag);
    if (!_running) return;
    var cacheTime = 30;
    if (state != null) {
      cacheTime = state.cacheTime.clamp(5, 3600);
      if (!state.notModified) {
        _etag = state.etag;
        if (!_hasData || state.publicData != _data) {
          _hasData = true;
          _data = state.publicData;
          for (final l in List.of(listeners)) {
            l(_data);
          }
        }
      }
    }
    _timer = Timer(Duration(seconds: cacheTime), () => unawaited(_tick()));
  }
}
