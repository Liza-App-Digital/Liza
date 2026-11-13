import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/chat/events/fluid_page_web_frame.dart';

void main() {
  test('ссылки страницы открываются в новой вкладке, модельный target перекрыт', () {
    final out = fluidPageLinksInNewTab(
      '<p><a href="https://shop.example/x">Купить</a> <A target="_self" href="y">Y</A><abbr>z</abbr></p>',
    );
    expect(
      out,
      '<p><a target="_blank" rel="noopener noreferrer" href="https://shop.example/x">Купить</a> '
      '<a target="_blank" rel="noopener noreferrer" target="_self" href="y">Y</A><abbr>z</abbr></p>',
    );
  });
}
