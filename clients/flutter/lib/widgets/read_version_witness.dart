import 'package:flutter/widgets.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/utils/read_marker_target.dart';

/// Факт кадра с конкретным MessageContent. Политику прочтения решает контроллер.
class ReadVersionEvidence {
  final String visibleRowId;
  final String displayedVersionId;
  final String displayedFingerprint;
  final bool Function() isCurrent;

  const ReadVersionEvidence({
    required this.visibleRowId,
    required this.displayedVersionId,
    required this.displayedFingerprint,
    required this.isCurrent,
  });
}

/// Не выполняет I/O и не считает build доказательством: callback только после
/// layout, пока именно этот child смонтирован и не скрыт через Offstage.
class ReadVersionWitness extends StatefulWidget {
  final Event original;
  final Event displayed;
  final Timeline timeline;
  final ValueChanged<ReadVersionEvidence> onRendered;
  final Widget child;

  const ReadVersionWitness({
    required this.original,
    required this.displayed,
    required this.timeline,
    required this.onRendered,
    required this.child,
    super.key,
  });

  @override
  State<ReadVersionWitness> createState() => _ReadVersionWitnessState();
}

class _ReadVersionWitnessState extends State<ReadVersionWitness> {
  int _buildGeneration = 0;

  bool _isOnstage() {
    if (!mounted) return false;
    var visible = true;
    context.visitAncestorElements((element) {
      final ancestor = element.widget;
      if (ancestor is Offstage && ancestor.offstage) visible = false;
      if (ancestor is SliverOffstage && ancestor.offstage) visible = false;
      return visible;
    });
    final box = context.findRenderObject();
    return visible &&
        box is RenderBox &&
        box.attached &&
        box.hasSize &&
        !box.size.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final generation = ++_buildGeneration;
    final original = widget.original;
    final timeline = widget.timeline;
    final originalFingerprint = readVersionFingerprint(original);
    final displayedFingerprint = readVersionFingerprint(widget.displayed);
    final displayedVersionId = widget.displayed.eventId;
    final callback = widget.onRendered;
    bool isCurrent() =>
        mounted &&
        generation == _buildGeneration &&
        _isOnstage() &&
        identical(widget.original.room, original.room) &&
        identical(widget.timeline, timeline) &&
        readVersionFingerprint(original) == originalFingerprint &&
        readVersionFingerprint(original.getDisplayEvent(timeline)) ==
            displayedFingerprint;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isCurrent()) return;
      callback(
        ReadVersionEvidence(
          visibleRowId: original.eventId,
          displayedVersionId: displayedVersionId,
          displayedFingerprint: displayedFingerprint,
          isCurrent: isCurrent,
        ),
      );
    });
    return widget.child;
  }
}
