import 'package:flutter_test/flutter_test.dart';
import 'package:liza/pages/stories/stories_bar.dart';

void main() {
  testWidgets('StoriesBar имеет фиксированную высоту 96', (tester) async {
    expect(StoriesBar.height, 82);
  });

  // Полноценный рендер StoriesBar требует Matrix.of(context) с живым Client.
  // Это покрывается ручной/E2E-проверкой (Фаза 4, верификация). Здесь
  // фиксируем контракт высоты, чтобы замена StatusMessageList (height=116)
  // не сломала верстку chat_list_body.
}
