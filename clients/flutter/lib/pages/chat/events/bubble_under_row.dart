import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Размер аватарки прочтения и шаг их перекрытия в кластере (SeenByAvatars).
const double kSeenAvatarSize = 16;
const double kSeenAvatarStep = 11;

/// Зазор между пузырём и строкой под ним и между реакциями и аватарками.
const double kUnderRowTopGap = 3;
const double kUnderRowInnerGap = 8;

/// Пузырь + ОДНА строка под ним: слева реакции, справа иконки прочтения
/// (одинаково для своих и чужих сообщений).
///
/// Строка не переносится. Ширина колонки = max(пузырь, строка): когда строка
/// уже пузыря — реакции у его левого края, иконки у правого; когда шире —
/// она выходит за край пузыря (у чужих вправо, у своих влево), а иконки
/// остаются прижаты к правому краю строки. Так «вылезание» не сужает пузырь
/// и не переносит текст (решение по заявке №60, голосовое Романа 02.11).
///
/// Свой RenderBox, а не Column: иконки должны встать у правого края именно
/// ПУЗЫРЯ, ширина которого заранее неизвестна, а IntrinsicWidth ломается на
/// LayoutBuilder внутри пузыря.
class BubbleWithUnderRow extends MultiChildRenderObjectWidget {
  BubbleWithUnderRow({
    required this.ownMessage,
    required Widget bubble,
    Widget? reactions,
    Widget? receipts,
    super.key,
  }) : super(
         children: [
           bubble,
           reactions ?? const SizedBox.shrink(),
           receipts ?? const SizedBox.shrink(),
         ],
       );

  final bool ownMessage;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBubbleWithUnderRow(ownMessage: ownMessage);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderBubbleWithUnderRow).ownMessage = ownMessage;
  }
}

class _RenderBubbleWithUnderRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _SlotData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _SlotData> {
  _RenderBubbleWithUnderRow({required bool ownMessage})
    : _ownMessage = ownMessage;

  bool _ownMessage;
  set ownMessage(bool value) {
    if (_ownMessage == value) return;
    _ownMessage = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SlotData) child.parentData = _SlotData();
  }

  List<RenderBox> get _slots {
    final slots = <RenderBox>[];
    for (var c = firstChild; c != null; c = childAfter(c)) {
      slots.add(c);
    }
    return slots;
  }

  _Plan _plan(
    BoxConstraints constraints,
    Size Function(RenderBox child, BoxConstraints c) measure,
  ) {
    final [bubble, reactions, receipts] = _slots;
    final bs = measure(bubble, constraints.loosen());
    const free = BoxConstraints();
    final rs = measure(reactions, free);
    final cs = measure(receipts, free);
    final hasRow = rs != Size.zero || cs != Size.zero;
    final gap = rs.width > 0 && cs.width > 0 ? kUnderRowInnerGap : 0.0;
    final rowWidth = rs.width + gap + cs.width;
    final rowHeight = rs.height > cs.height ? rs.height : cs.height;
    final fullWidth = bs.width > rowWidth ? bs.width : rowWidth;
    final height = bs.height + (hasRow ? kUnderRowTopGap + rowHeight : 0);
    return _Plan(
      bubble: bs,
      reactions: rs,
      receipts: cs,
      rowHeight: rowHeight,
      fullWidth: fullWidth,
      size: constraints.constrain(Size(fullWidth, height)),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _plan(constraints, (c, k) => c.getDryLayout(k)).size;

  @override
  void performLayout() {
    final plan = _plan(constraints, (c, k) {
      c.layout(k, parentUsesSize: true);
      return c.size;
    });
    size = plan.size;
    final [bubble, reactions, receipts] = _slots;
    // Строка занимает [rowLeft, rowLeft + fullWidth]; у чужих она растёт
    // вправо от левого края пузыря, у своих — влево от правого.
    final rowLeft = _ownMessage ? size.width - plan.fullWidth : 0.0;
    (bubble.parentData! as _SlotData).offset = Offset(
      _ownMessage ? size.width - plan.bubble.width : 0,
      0,
    );
    final rowTop = plan.bubble.height + kUnderRowTopGap;
    (reactions.parentData! as _SlotData).offset = Offset(
      rowLeft,
      rowTop + (plan.rowHeight - plan.reactions.height) / 2,
    );
    (receipts.parentData! as _SlotData).offset = Offset(
      rowLeft + plan.fullWidth - plan.receipts.width,
      rowTop + (plan.rowHeight - plan.receipts.height) / 2,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  // Строка может выступать за размер колонки — тап по выступающей части тоже
  // должен доходить до реакций и аватарок.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return super.hitTest(result, position: position);
  }
}

class _SlotData extends ContainerBoxParentData<RenderBox> {}

class _Plan {
  const _Plan({
    required this.bubble,
    required this.reactions,
    required this.receipts,
    required this.rowHeight,
    required this.fullWidth,
    required this.size,
  });
  final Size bubble;
  final Size reactions;
  final Size receipts;
  final double rowHeight;
  final double fullWidth;
  final Size size;
}
