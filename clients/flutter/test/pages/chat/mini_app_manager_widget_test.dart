import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/chat/mini_app_manager.dart';

import '../../utils/test_client.dart';

void main() {
  final manager = MiniAppManager.instance;
  late Client client;
  late Room room;

  setUpAll(() async {
    client = await prepareTestClient();
    room = Room(id: '!widgets:example.invalid', client: client);
  });

  setUp(() {
    manager.closeAll();
    manager.windowsSupported = true;
  });

  tearDown(() {
    manager.closeAll();
    manager.windowsSupported = false;
  });

  Event widgetEvent(String id) => Event(
    type: EventTypes.Message,
    eventId: id,
    senderId: '@bot:example.invalid',
    originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
    room: room,
    content: {'msgtype': 'm.text', 'body': 'Карточка'},
  );

  test('развёрнутый виджет открывается панелью, не окном ОС', () {
    manager.openWidget(widgetEvent(r'$a'), title: 'Карточка');
    final app = manager.activeApp!;
    expect(app.kind, MiniAppKind.widget);
    expect(app.isPageLike, isTrue);
    expect(app.detached, isFalse);
    expect(app.widgetEvent!.eventId, r'$a');
    expect(app.appUrl, r'$a');
    expect(app.appId, kWidgetExpandedAppId);
  });

  test('другой виджет заменяет панель, а не плодит вкладки', () {
    manager.openWidget(widgetEvent(r'$a'), title: 'Первая');
    manager.openWidget(widgetEvent(r'$b'), title: 'Вторая');
    expect(manager.apps, hasLength(1));
    expect(manager.activeApp!.appUrl, r'$b');
    expect(manager.activeApp!.appName, 'Вторая');
    expect(manager.activeApp!.widgetEvent!.eventId, r'$b');
  });

  test('закрытие убирает панель', () {
    manager.openWidget(widgetEvent(r'$a'), title: 'Карточка');
    manager.close(kWidgetExpandedAppId);
    expect(manager.activeApp, isNull);
    expect(manager.apps, isEmpty);
  });
}
