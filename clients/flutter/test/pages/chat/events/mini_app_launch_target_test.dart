// ledger:RL-miniapp-launch-from-catalog
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/chat/events/mini_app_launch_content.dart';
import 'package:liza/pages/chat/mini_app_registry.dart';

// Подделка launch-карточки (review liza-capsules 29.10, находка 2a): участник
// чата шлёт `app_id: capsules` со своим `app_url`, клиент жертвы дописывал к нему
// initData капсул. Адрес и тип должны браться из каталога.
void main() {
  final catalog = [
    CatalogApp(
      appId: 'capsules',
      name: 'Капсулы созвонов',
      url: 'https://platform.capsule.laba.pro/',
      icon: '',
      type: 'first_party',
    ),
    CatalogApp(
      appId: 'weather',
      name: 'Погода',
      url: 'https://weather.example.test/',
      icon: '',
      type: 'third_party',
    ),
  ];

  test(
    'чужой app_url у приложения из каталога заменяется адресом каталога [AC:RL-miniapp-launch-from-catalog/1]',
    () {
      final t = resolveLaunchTarget(
        appId: 'capsules',
        eventUrl: 'https://evil.example.test/steal',
        catalog: catalog,
      );
      expect(t?.url, 'https://platform.capsule.laba.pro/');
      expect(t?.type, 'first_party');
    },
  );

  test('тип берётся из каталога, а не из карточки без app_type [AC:RL-miniapp-launch-from-catalog/1]', () {
    final t = resolveLaunchTarget(
      appId: 'weather',
      eventUrl: 'https://weather.example.test/',
      catalog: catalog,
    );
    expect(t?.type, 'third_party');
  });

  test('приложения нет в каталоге — адрес карточки, но только third_party [AC:RL-miniapp-launch-from-catalog/2]', () {
    final t = resolveLaunchTarget(
      appId: 'my-own-app',
      eventUrl: 'https://my.example.test/',
      catalog: catalog,
    );
    expect(t?.url, 'https://my.example.test/');
    expect(t?.type, 'third_party');
  });

  test('без app_id карточка не становится first_party [AC:RL-miniapp-launch-from-catalog/2]', () {
    final t = resolveLaunchTarget(
      appId: null,
      eventUrl: 'https://evil.example.test/',
      catalog: catalog,
    );
    expect(t?.type, 'third_party');
  });

  test('каталог не загрузился — не открываем [AC:RL-miniapp-launch-from-catalog/3]', () {
    expect(
      resolveLaunchTarget(
        appId: 'capsules',
        eventUrl: 'https://evil.example.test/steal',
        catalog: null,
      ),
      isNull,
    );
  });

  test('не-https адрес не открываем [AC:RL-miniapp-launch-from-catalog/3]', () {
    expect(
      resolveLaunchTarget(
        appId: 'my-own-app',
        eventUrl: 'http://my.example.test/',
        catalog: catalog,
      ),
      isNull,
    );
    expect(
      resolveLaunchTarget(
        appId: 'bad',
        eventUrl: 'https://x.example.test/',
        catalog: [
          CatalogApp(
            appId: 'bad',
            name: 'b',
            url: 'javascript:alert(1)',
            icon: '',
            type: 'first_party',
          ),
        ],
      ),
      isNull,
    );
  });
}
