// ignore_for_file: depend_on_referenced_packages

// Страж дубля баннера на macOS у скрытого окна (2026-11-06, DM в фоне):
// система показала APNs-баннер, `didReceiveRemoteNotification` из-за App Nap
// до процесса ещё не дошёл, догоняющий /sync через минуту-две рисовал второй,
// локальный баннер того же сообщения. Локальный путь теперь спрашивает
// шторку (`isDeliveredByOs`) и по найденному баннеру молчит.

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/background_push.dart';

const _event = r'$evt:synapse.liza.laba.prodamus.tech';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('баннер уже в шторке → true и отметка «нативно получено»', () async {
    final push = BackgroundPush.forTest(const []);
    final found = await push.isDeliveredByOs(_event, lookup: (_) async => true);
    expect(found, isTrue);
    // Опоздавший onMessage этого события уйдёт в дубль, а не в pushHelper.
    expect(push.isNativelyReceived(_event), isTrue);
  });

  test('баннера нет → false, отметки нет', () async {
    final push = BackgroundPush.forTest(const []);
    final found = await push.isDeliveredByOs(_event, lookup: (_) async => false);
    expect(found, isFalse);
    expect(push.isNativelyReceived(_event), isFalse);
  });

  test('onMessage пришёл, пока ждали шторку → true', () async {
    final push = BackgroundPush.forTest(const []);
    final found = await push.isDeliveredByOs(
      _event,
      lookup: (id) async {
        push.markNativelyReceived(id);
        return false;
      },
    );
    expect(found, isTrue);
  });

  test('уже отмечено нативно → шторку не спрашиваем', () async {
    final push = BackgroundPush.forTest(const []);
    push.markNativelyReceived(_event);
    var asked = false;
    final found = await push.isDeliveredByOs(
      _event,
      lookup: (_) async {
        asked = true;
        return false;
      },
    );
    expect(found, isTrue);
    expect(asked, isFalse);
  });

  test('пустой event_id → false без запроса', () async {
    final push = BackgroundPush.forTest(const []);
    var asked = false;
    final found = await push.isDeliveredByOs(
      '',
      lookup: (_) async {
        asked = true;
        return true;
      },
    );
    expect(found, isFalse);
    expect(asked, isFalse);
  });
}
