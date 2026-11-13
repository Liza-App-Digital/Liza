import 'package:flutter/gestures.dart';

/// Хостовый гейт тапа. Мосту виджета не верим: секрет моста код виджета
/// читает из `document.scripts`, значит «тап» из JS подделывается. Действие,
/// требующее тапа, разрешает только касание, которое видел сам Flutter:
/// смещение ≤ [kTouchSlop], длительность ≤ [maxDuration], без прокрутки ленты
/// между down и up. Один тап — одно действие (как в Telegram), окно — 1,5 с.
class TgWidgetTapGate {
  static const Duration maxDuration = Duration(milliseconds: 500);
  static const Duration window = Duration(milliseconds: 1500);

  final DateTime Function() _now;

  TgWidgetTapGate({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Map<int, _Down> _downs = {};
  DateTime? _tapAt;
  bool _tapUsed = true;
  bool _feedScrolling = false;
  DateTime? _lastTouch;

  /// Последнее касание поверх виджета (окно для вибро).
  DateTime? get lastTouch => _lastTouch;

  void onPointer(PointerEvent event) {
    final now = _now();
    _lastTouch = now;
    switch (event) {
      case PointerDownEvent():
        _downs[event.pointer] = _Down(event.position, now, _feedScrolling);
      case PointerMoveEvent():
        final d = _downs[event.pointer];
        if (d != null && (event.position - d.position).distance > kTouchSlop) {
          d.moved = true;
        }
      case PointerUpEvent():
        final d = _downs.remove(event.pointer);
        if (d == null) return;
        final isTap =
            !d.moved &&
            !d.scrolled &&
            !_feedScrolling &&
            (event.position - d.position).distance <= kTouchSlop &&
            now.difference(d.at) <= maxDuration;
        if (isTap) {
          _tapAt = now;
          _tapUsed = false;
        }
      case PointerCancelEvent():
        _downs.remove(event.pointer);
      default:
        break;
    }
  }

  /// Лента прокручивается: касание, начатое или законченное в это время, —
  /// не тап (в том числе конец вертикального свайпа поверх виджета).
  void setFeedScrolling(bool scrolling) {
    _feedScrolling = scrolling;
    if (scrolling) {
      for (final d in _downs.values) {
        d.scrolled = true;
      }
    }
  }

  /// Web: касаний хост не видит, сигнал активации iframe даёт сам движок.
  void onActivation() {
    _tapAt = _now();
    _tapUsed = false;
    _lastTouch = _tapAt;
  }

  /// Одно действие на тап, только в окне после него.
  bool consume() {
    final at = _tapAt;
    if (at == null || _tapUsed) return false;
    if (_now().difference(at) > window) return false;
    _tapUsed = true;
    return true;
  }
}

class _Down {
  final Offset position;
  final DateTime at;
  bool moved = false;
  bool scrolled;

  _Down(this.position, this.at, this.scrolled);
}
