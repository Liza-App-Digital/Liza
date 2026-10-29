import 'package:flutter/widgets.dart';

/// Размер аватарки прочтения и шаг их перекрытия в кластере (SeenByAvatars).
const double kSeenAvatarSize = 16;
const double kSeenAvatarStep = 11;

/// Самый плотный шаг, при котором соседние аватарки ещё различимы.
const double kSeenAvatarMinStep = 4;

/// Зазор между пузырём и кластером аватарок прочтения.
const double kReceiptsSideGap = 3;

/// Минимальная ширина бокового слота: кластер из двух аватарок плюс зазор. Слот
/// такой ширины есть у сообщения ВСЕГДА (и без аватарок), поэтому появление
/// одной-двух аватарок не меняет ни ширину пузыря, ни перенос его текста.
const double kReceiptsSideMinWidth =
    kReceiptsSideGap + kSeenAvatarSize + kSeenAvatarStep;

/// Пузырь сообщения с аватарками «прочитал до сюда» СБОКУ от его нижнего края:
/// у своих сообщений — слева, у чужих — справа (заявка №60). Раньше кластер
/// стоял отдельной строкой ПОД пузырём (+18 px): переезд границы чтения менял
/// высоту двух сообщений, и лента «скакала» под глазами читающего.
///
/// Высота строки = высота пузыря: кластер (16 px) ниже любого пузыря и
/// прижат к его низу. Кладётся ВНУТРЬ выровненного контейнера пузыря, а не в
/// gutter `MessageBubbleRow`: тот стоит первым элементом ряда, и на широком
/// экране аватарки оказались бы далеко от короткого пузыря.
///
/// [reserve] == false (каналы, Liza News с hide_read_receipts) — слота нет,
/// ширина пузыря прежняя.
class BubbleReceiptsSide extends StatelessWidget {
  final bool ownMessage;
  final bool reserve;

  /// Кластер под доступную ему ширину: бокового места мало (длинный пузырь на
  /// телефоне) — аватарки перекрываются плотнее, пузырь при этом НЕ сужается.
  final Widget Function(double maxWidth)? cluster;
  final Widget child;

  const BubbleReceiptsSide({
    required this.ownMessage,
    required this.reserve,
    required this.cluster,
    required this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (!reserve) return child;
    final cluster = this.cluster;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Ширина пузыря от числа читателей не зависит НИКОГДА: пузырь получает
        // всё, кроме минимального слота, а кластер — только то, что осталось
        // сбоку от уже разложенного пузыря (Row раскладывает не-flex первым).
        final bubbleMax = constraints.maxWidth.isFinite
            ? constraints.maxWidth - kReceiptsSideMinWidth
            : double.infinity;
        final bubble = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: bubbleMax),
          child: child,
        );
        final slot = Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: kReceiptsSideMinWidth),
            child: LayoutBuilder(
              builder: (context, slotConstraints) => Align(
                alignment: ownMessage
                    ? AlignmentDirectional.bottomEnd
                    : AlignmentDirectional.bottomStart,
                widthFactor: 1,
                heightFactor: 1,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: ownMessage ? 0 : kReceiptsSideGap,
                    end: ownMessage ? kReceiptsSideGap : 0,
                  ),
                  child: cluster == null
                      ? const SizedBox.shrink()
                      : cluster(slotConstraints.maxWidth - kReceiptsSideGap),
                ),
              ),
            ),
          ),
        );
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: ownMessage ? [slot, bubble] : [bubble, slot],
        );
      },
    );
  }
}

/// Шаг перекрытия и число видимых аватарок кластера под ширину [maxWidth]:
/// сначала сжимаем шаг (до [kSeenAvatarMinStep]), и только если всё равно не
/// влезает — уводим лишних в «+N». Чистая функция — проверяется тестом.
({double step, int shown}) fitSeenAvatars({
  required int total,
  required int maxShown,
  required double maxWidth,
}) {
  var shown = total > maxShown ? maxShown : total;
  int slotsFor(int s) => s + (total > s ? 1 : 0);
  double widthFor(int s, double step) =>
      kSeenAvatarSize + (slotsFor(s) - 1) * step;
  if (!maxWidth.isFinite || widthFor(shown, kSeenAvatarStep) <= maxWidth) {
    return (step: kSeenAvatarStep, shown: shown);
  }
  while (shown > 1 && widthFor(shown, kSeenAvatarMinStep) > maxWidth) {
    shown--;
  }
  final slots = slotsFor(shown);
  final step = slots <= 1
      ? kSeenAvatarStep
      : ((maxWidth - kSeenAvatarSize) / (slots - 1)).clamp(
          kSeenAvatarMinStep,
          kSeenAvatarStep,
        );
  return (step: step, shown: shown);
}
