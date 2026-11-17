import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/chat/tg_widget/tg_widget_model.dart';

void main() {
  group('маркер подробной версии', () {
    // AC:RL-telegram-widgets/11
    test('класс в списке и одинарные кавычки', () {
      expect(tgWidgetHasDetails('<div class="a liza-more b"></div>'), isTrue);
      expect(tgWidgetHasDetails("<div class='liza-more'></div>"), isTrue);
      expect(tgWidgetHasDetails('<div class="liza-more"></div>'), isTrue);
    });

    test('похожее имя класса и другие атрибуты — не маркер', () {
      expect(tgWidgetHasDetails('<div class="liza-more-x"></div>'), isFalse);
      expect(tgWidgetHasDetails('<div id="liza-more"></div>'), isFalse);
      expect(tgWidgetHasDetails('<div class="liza"></div>'), isFalse);
      expect(tgWidgetHasDetails('<div></div>'), isFalse);
    });

    test('блок виджета отдаёт признак', () {
      final block = TgWidgetBlock.tryParse({
        'v': 1,
        'widget_id': '1',
        'bot_id': '@b:example.invalid',
        'sender': '@b:example.invalid',
        'room_id': '!r:example.invalid',
        'html': '<div class="liza-more">x</div>',
        'width': 0,
        'height': 0,
        'is_shared': false,
        'allow_queries': true,
        'protect_content': false,
        'kid': 'k',
        'sig': 's',
      });
      expect(block, isNotNull);
      expect(block!.hasDetails, isTrue);
    });
  });
}
