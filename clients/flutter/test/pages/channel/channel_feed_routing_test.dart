import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Канал должен рендериться через ChatPageWithRoom/ChatController, а не через
// собственный ChannelFeedView: иначе лента не получает read-marker, реакции,
// медиа и пагинацию (см.
// docs/superpowers/specs/2026-07-24-channels-fixes-design.md).
// Структурный тест: полноценный widget-тест ChatPage требует поднятого
// Matrix-клиента с комнатой-каналом, что несоразмерно проверяемому факту.

void main() {
  group('маршрутизация канала', () {
    test('chat.dart не перехватывает канал отдельным экраном', () {
      final file = File('lib/pages/chat/chat.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'Тест должен запускаться из clients/flutter/',
      );
      final source = file.readAsStringSync();

      expect(
        source.contains('ChannelFeedView'),
        isFalse,
        reason:
            'канал должен идти через ChatPageWithRoom, а не ChannelFeedView',
      );
    });

    test('файл channel_feed_view.dart удалён', () {
      expect(
        File('lib/pages/channel/channel_feed_view.dart').existsSync(),
        isFalse,
        reason: 'лента канала переехала в ChatController; заглушка не нужна',
      );
    });

    test('кнопка «история канала» переехала в AppBar чата', () {
      final controller = File('lib/pages/chat/chat.dart').readAsStringSync();
      expect(
        controller.contains('Future<void> addChannelStory()'),
        isTrue,
        reason: 'ChatController должен уметь публиковать историю канала',
      );

      // Пробелы схлопываем: dart format переносит длинное условие на две строки.
      final view = File(
        'lib/pages/chat/chat_view.dart',
      ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      expect(
        view.contains('controller.addChannelStory'),
        isTrue,
        reason: 'кнопка истории канала должна быть в _appBarActions',
      );
      expect(view.contains('addChannelStory'), isTrue);

      // Смежность гейта и кнопки: одного упоминания isChannel в файле
      // недостаточно — оно может относиться к другому месту, а гейт самой
      // кнопки при этом окажется снят (найдено ревью, деградация ловится
      // только проверкой соседства, а не поиском подстроки по всему файлу).
      final gate =
          'controller.room.isChannel && controller.room.ownPowerLevel >= adminPowerLevel';
      final gateIndex = view.indexOf(gate);
      expect(
        gateIndex,
        isNot(-1),
        reason:
            'гейт "isChannel && ownPowerLevel >= adminPowerLevel" должен стоять прямо '
            'перед кнопкой addChannelStory (проверяем полное условие целиком, '
            'не отдельно isChannel — иначе снятый гейт с отвлекающим '
            'упоминанием isChannel в другом месте файла проходит незамеченным)',
      );

      final callIndex = view.indexOf('controller.addChannelStory', gateIndex);
      expect(
        callIndex,
        isNot(-1),
        reason: 'addChannelStory должен встречаться после гейта',
      );

      final between = view.substring(gateIndex + gate.length, callIndex);
      // Между условием и вызовом — только разметка самой IconButton, никакого
      // другого элемента списка _appBarActions (иначе гейт мог бы относиться
      // к соседней кнопке, а не к этой).
      expect(
        between.length,
        lessThan(200),
        reason:
            'между гейтом и addChannelStory должна быть только разметка '
            'кнопки — большая дистанция означает, что гейт стоит не над этой '
            'кнопкой',
      );
      expect(
        between.contains('if ('),
        isFalse,
        reason:
            'между гейтом и addChannelStory не должно быть начала другого '
            'условного элемента списка',
      );
    });
  });
}
