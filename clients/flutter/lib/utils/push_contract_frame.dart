import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/push_contract_outbox.dart';
import 'package:liza/utils/push_contract_session.dart';

/// Фиксирует параметры конкретного builder после кадра и отзывает их при
/// unmount/offstage. Никаких предположений о видимости пикселей или баннера.
class PushContractFrame extends StatefulWidget {
  const PushContractFrame._(
    this.session,
    this.room,
    this.values,
    this.current,
    this.child,
  );
  final PushContractSession session;
  final String? room;
  final ContractJson values;
  final String? Function() current;
  final Widget child;

  static Widget row(
    Room room,
    String surface,
    int count,
    bool shown,
    Widget child,
  ) {
    final s = PushContractSession.observing(room.client);
    if (s == null || !s.isActiveAccount()) return child;
    String? current() => s.roomFingerprint(room);
    final fp = current();
    if (fp == null) return child;
    return PushContractFrame._(
      s,
      room.id,
      {
        'stage': 'after_frame',
        'surface_id': surface,
        'revision': s.revision,
        'model_fingerprint': fp,
        'notification_count': count,
        'show_unread': shown,
      },
      current,
      child,
    );
  }

  static Widget nav(
    Client client,
    String scope,
    String? scopeRoomId,
    bool Function(Room) filter,
    int count,
    Widget child,
  ) {
    final s = PushContractSession.observing(client);
    if (s == null || !s.isActiveAccount()) return child;
    ({String fingerprint, int count})? expected() {
      if (scope == 'all') return s.aggregate(null);
      if (scope == 'except_current') {
        return s.aggregate((r) => r.id != scopeRoomId);
      }
      if (scope == 'space') {
        final space = scopeRoomId == null
            ? null
            : client.getRoomById(scopeRoomId);
        if (space == null) return null;
        final children = space.spaceChildren.map((e) => e.roomId).toSet();
        return s.aggregate((r) => children.contains(r.id));
      }
      return s.aggregate(filter);
    }

    final aggregate = expected();
    if (aggregate == null) return child;
    return PushContractFrame._(
      s,
      null,
      {
        'stage': 'after_frame',
        'surface_id': 'navigation',
        'scope': scope,
        'scope_id': contractFingerprint([scope, scopeRoomId]),
        'revision': s.revision,
        'model_fingerprint': aggregate.fingerprint,
        'observed': count,
        'expected': aggregate.count,
      },
      () => expected()?.fingerprint,
      child,
    );
  }

  @override
  State<PushContractFrame> createState() => _FrameState();
}

class _FrameState extends State<PushContractFrame> {
  bool _onstage() {
    if (!mounted || context.findRenderObject()?.attached != true) return false;
    var onstage = true;
    context.visitAncestorElements((e) {
      final w = e.widget;
      if (w is Offstage && w.offstage) onstage = false;
      return onstage;
    });
    return onstage;
  }

  @override
  void didUpdateWidget(PushContractFrame old) {
    super.didUpdateWidget(old);
    if (!identical(old.session, widget.session) || old.room != widget.room) {
      if (old.session.frames.remove(this) != null) old.session.changed();
    }
  }

  @override
  void dispose() {
    if (widget.session.frames.remove(this) != null) widget.session.changed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final built = widget;
    final previous = built.session.frames[this]?.data;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !identical(widget, built) ||
          !identical(
            PushContractSession.observing(built.session.client),
            built.session,
          ) ||
          !_onstage() ||
          built.values['model_fingerprint'] != built.current()) {
        return;
      }
      final frames = built.session.frames;
      if (!frames.containsKey(this) && frames.length >= 128) {
        built.session.lost++;
        return;
      }
      if (!mapEquals(previous, built.values)) built.session.changed();
      frames[this] = (
        room: built.room,
        data: built.values,
        current: () => _onstage() ? built.current() : null,
      );
    });
    return built.child;
  }
}
