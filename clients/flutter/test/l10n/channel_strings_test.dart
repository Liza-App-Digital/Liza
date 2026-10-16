// ledger:RL-sole-owner-leave-all-exits
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Каждый ключ, добавленный в intl_en.arb, обязан быть и в intl_ru.arb:
// CI-гейта на это нет, при отсутствии Flutter молча подставляет английский
// (см. CLAUDE.md, ловушка l10n).
//
// Вторая половина файла — структурные стражи подстановок «канальных» строк.
// Полноценный widget-тест потребовал бы поднятого Matrix-клиента с комнатой
// типа channel; здесь достаточно проверить, что подстановка стоит и стоит
// под ГЕЙТОМ isChannel. Проверяем ТОЧНУЮ форму тернарника целиком, а не
// отдельные токены: `view.contains('channelMembers')` остаётся true и после
// инверсии условия (`room.isChannel` → `!room.isChannel`), то есть после
// диверсии, которая ломает ровно то, что тест должен защищать —
// формулировки обычных чатов.

/// Убирает пробелы/переносы строк и «шум» обращения к локализации, чтобы
/// сравнение не было хрупким к переформатированию (`dart format` переносит
/// `L10n.of(\n context,\n )` по-разному в зависимости от отступа), но
/// оставалось точным к самому условию: инверсия (`!`, перестановка ветвей
/// тернарника) меняет строку даже после нормализации.
String _normalize(String source) => source
    .replaceAll(RegExp(r'L10n\.of\(\s*context\s*,?\s*\)\s*\.\s*'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAllMapped(RegExp(r'\s*([(),?:])\s*'), (m) => m.group(1)!)
    // Висячая запятая перед `)` — тоже решение форматтера, не смысла.
    .replaceAll(',)', ')')
    .trim();

String _read(String path) {
  final file = File(path);
  expect(
    file.existsSync(),
    isTrue,
    reason: 'Тест должен запускаться из clients/flutter/ (нет $path)',
  );
  return file.readAsStringSync();
}

void main() {
  group('строки каналов', () {
    late Map<String, dynamic> en;
    late Map<String, dynamic> ru;

    setUp(() {
      en = jsonDecode(_read('lib/l10n/intl_en.arb')) as Map<String, dynamic>;
      ru = jsonDecode(_read('lib/l10n/intl_ru.arb')) as Map<String, dynamic>;
    });

    test('ключи каналов присутствуют в обоих файлах', () {
      const keys = [
        'channelDetails',
        'channelViewCount',
        'channelCommentsCount',
        'openChannelDiscussion',
        'deleteChannel',
        'channelLeave',
        'channelSubscribersCount',
        'channelNewPostHint',
        'channelDiscussionOpenFailed',
        'channelAddComment',
        'channelDescription',
        'setChannelDescription',
        'noChannelDescriptionYet',
        'channelDescriptionHasBeenChanged',
        'channelPermissions',
        'channelPermissionsDescription',
        'leftTheChannel',
      ];
      for (final key in keys) {
        expect(en.containsKey(key), isTrue, reason: '$key отсутствует в en');
        expect(ru.containsKey(key), isTrue, reason: '$key отсутствует в ru');
      }
    });

    test('русские строки каналов не пустые и не англоязычные', () {
      const keys = [
        'channelDetails',
        'openChannelDiscussion',
        'deleteChannel',
        'channelLeave',
        'channelSubscribersCount',
        'channelNewPostHint',
        'channelDescription',
        'setChannelDescription',
        'noChannelDescriptionYet',
        'channelDescriptionHasBeenChanged',
        'channelPermissions',
        'channelPermissionsDescription',
        'leftTheChannel',
      ];
      for (final key in keys) {
        final value = ru[key] as String;
        expect(value.isNotEmpty, isTrue, reason: '$key пустой в ru');
        expect(
          RegExp(r'[а-яА-Я]').hasMatch(value),
          isTrue,
          reason: '$key в ru выглядит непереведённым: "$value"',
        );
      }
    });

    test('счётчик подписчиков канала имеет русские формы plural', () {
      // Русский требует one/few/many/other; `=1/other` из английского даёт
      // «5 подписчик». Ключ с числом — единственный такой в этой пачке.
      final value = ru['channelSubscribersCount'] as String;
      for (final form in ['one{', 'few{', 'many{', 'other{']) {
        expect(
          value.contains(form),
          isTrue,
          reason: 'channelSubscribersCount без формы $form: "$value"',
        );
      }
      final meta = ru['@channelSubscribersCount'] as Map<String, dynamic>;
      final placeholders = meta['placeholders'] as Map<String, dynamic>;
      final count = placeholders['count'] as Map<String, dynamic>;
      expect(
        count['type'],
        'int',
        reason: 'плейсхолдер count должен быть объявлен как int',
      );
    });
  });

  group('подстановка канальных строк в UI', () {
    test('заголовок списка участников — «Подписчики» только в канале', () {
      final view = _normalize(
        _read('lib/pages/chat_details/chat_details_view.dart'),
      );
      // Оба места (кнопка в шапке и заголовок секции) — под одним гейтом.
      // `Text(` в начале — якорь: без него подстрока `room.isChannel ? …`
      // находится и внутри `!room.isChannel ? …`, то есть инверсия гейта
      // (обычный чат получил бы «подписчиков») прошла бы по зелёному.
      final expected = _normalize('''
Text(
  room.isChannel
      ? L10n.of(context).channelSubscribersCount(actualMembersCount)
      : L10n.of(context).countParticipants(actualMembersCount)''');
      expect(
        expected.allMatches(view).length,
        2,
        reason:
            'обе подстановки счётчика участников должны быть ровно '
            'room.isChannel ? channelSubscribersCount : countParticipants',
      );
    });

    // ledger:RL-leave-chat-not-delete
    // AC:RL-leave-chat-not-delete/8 — подпись, заголовок, тело и кнопка берутся
    // ровно из общей таблицы leaveActionKind, а не из локальных тернарников.
    // Real-widget этот call-site не покрывает: `chatContextAction` — метод
    // ChatListController, зовущий Overlay.of(posContext).findRenderObject(),
    // то есть требует подъёма всего ChatListView с sync и пространствами.
    // Это осознанный source-scan, а не мимикрия под real-widget.
    test('выход подписан через таблицу leaveActionKind, а не «Удалить чат»', () {
      final menu = _normalize(
        _read('lib/widgets/chat_settings_popup_menu.dart'),
      );
      final list = _normalize(_read('lib/pages/chat_list/chat_list.dart'));
      final space = _normalize(_read('lib/pages/chat_list/space_view.dart'));

      // LABA-2540: слово «удалить» на действии leave() — ровно тот дефект,
      // из-за которого заведён тикет. Ключи-«удаления» не должны попадать
      // ни в подпись пункта, ни в диалог выхода.
      for (final (name, source) in [
        ('chat_settings_popup_menu.dart', menu),
        ('chat_list.dart', list),
        ('space_view.dart', space),
      ]) {
        expect(
          source.contains('chatDeleteChat'),
          isFalse,
          reason:
              '$name: ключ chatDeleteChat удалён — «Удалить» на действии '
              'leave() и был жалобой LABA-2540',
        );
      }
      // `deleteChat` остаётся правдивым ровно в одном месте — на корзине
      // экрана «Архив», где вызывается forget(). В путях выхода его быть не
      // должно (общий ключ на обратимом и необратимом действии — RK-1).
      expect(
        list.contains('deleteChat'),
        isFalse,
        reason:
            'chat_list.dart: пункт выхода зовёт leave(), а не forget() — '
            'ключ deleteChat принадлежит только архивной корзине',
      );

      // Якоря против инверсии гейта: сама по себе подстрока `leaveActionLabel`
      // осталась бы true и после подмены аргумента.
      expect(
        menu.contains(
          _normalize('Text(leaveActionLabel(L10n.of(context), leaveKind))'),
        ),
        isTrue,
        reason: 'подпись пункта меню шапки — из таблицы leaveActionKind',
      );
      for (final (name, source) in [
        ('chat_settings_popup_menu.dart', menu),
        ('chat_list.dart', list),
        ('space_view.dart', space),
      ]) {
        expect(
          source.contains(_normalize('title: leaveLabel')) &&
              source.contains(
                _normalize(
                  'message: leaveActionMessage(L10n.of(context), leaveKind)',
                ),
              ) &&
              source.contains(_normalize('okLabel: leaveLabel')),
          isTrue,
          reason:
              '$name: заголовок, тело и кнопка диалога выхода обязаны идти из '
              'одной таблицы — рассинхрон «Удалить»/«в архив»/«Покинуть» и был '
              'предметом LABA-2540',
        );
      }

      // AC:RL-leave-chat-not-delete/10 — паритет новых ключей. CI-гейта на это
      // нет: при дыре в ru Flutter молча подставит английский.
      final en = jsonDecode(_read('lib/l10n/intl_en.arb')) as Map;
      final ru = jsonDecode(_read('lib/l10n/intl_ru.arb')) as Map;
      for (final key in [
        'leaveChatAction',
        'leaveSpaceDescription',
        'unsubscribeFromCompanyDescription',
        'archiveRoomDescription',
      ]) {
        expect(en.containsKey(key), isTrue, reason: '$key нет в intl_en.arb');
        expect(ru.containsKey(key), isTrue, reason: '$key нет в intl_ru.arb');
        expect(
          RegExp('[а-яА-ЯёЁ]').hasMatch(ru[key] as String),
          isTrue,
          reason: '$key в intl_ru.arb не переведён',
        );
      }
      expect(
        en.containsKey('chatDeleteChat') || ru.containsKey('chatDeleteChat'),
        isFalse,
        reason: 'chatDeleteChat («Удалить чат» на leave()) удалён из обоих',
      );

      // Передача владения (канал, группа, пространство) перехватывает выход
      // раньше общей ветки — во ВСЕХ трёх точках.
      // AC:RL-sole-owner-leave-all-exits/6
      for (final (name, path, leaveMarker) in [
        (
          'chat_settings_popup_menu.dart',
          'lib/widgets/chat_settings_popup_menu.dart',
          'case ChatPopupMenuActions.leave:',
        ),
        (
          'chat_list.dart',
          'lib/pages/chat_list/chat_list.dart',
          'case ChatContextAction.leave:',
        ),
        (
          'space_view.dart',
          'lib/pages/chat_list/space_view.dart',
          'case SpaceActions.leave:',
        ),
      ]) {
        final src = _normalize(_read(path));
        final branch = src.indexOf(_normalize(leaveMarker));
        final handoff = src.indexOf('handleSoleOwnerLeave(context,', branch);
        final dialog = src.indexOf('showOkCancelAlertDialog(', branch);
        expect(branch, isNonNegative, reason: name);
        expect(handoff, isNonNegative, reason: '$name: нет передачи владения');
        expect(
          handoff,
          lessThan(dialog),
          reason: '$name: передача владения должна идти ДО обычного выхода',
        );
      }
    });

    // ledger:RL-delete-company-via-support
    // AC:RL-delete-company-via-support/8 — три точки входа берут вид из ОДНОЙ
    // таблицы (через leaveActionKindFor), space_view больше не гейтит выход
    // своим isOwnCompany; новые ключи есть в обоих arb и не носят «deleteChat».
    // Source-scan по той же причине, что и AC-8 RL-leave (см. выше).
    test(
      '«Удалить компанию через поддержку»: SSOT в трёх точках + паритет arb',
      () {
        final menu = _normalize(
          _read('lib/widgets/chat_settings_popup_menu.dart'),
        );
        final list = _normalize(_read('lib/pages/chat_list/chat_list.dart'));
        final space = _normalize(_read('lib/pages/chat_list/space_view.dart'));

        for (final (name, source) in [
          ('chat_settings_popup_menu.dart', menu),
          ('chat_list.dart', list),
          ('space_view.dart', space),
        ]) {
          expect(
            source.contains('leaveActionKindFor(context,'),
            isTrue,
            reason:
                '$name: вид пункта выхода — из leaveActionKindFor, не свой гейт',
          );
          expect(
            source.contains('LeaveActionKind.deleteCompanyViaSupport'),
            isTrue,
            reason:
                '$name: пункт заявки в поддержку рисуется по исходу таблицы',
          );
          expect(
            source.contains(_normalize('Icon(Icons.support_agent_outlined)')),
            isTrue,
            reason: '$name: иконка заявки — поддержка, не корзина',
          );
        }
        expect(
          space.contains(_normalize('if (!isOwnCompany)')),
          isFalse,
          reason:
              'space_view.dart: собственный гейт isOwnCompany шёл мимо таблицы '
              'и рисовал корзину на leave — рецидив LABA-2540',
        );

        final en = jsonDecode(_read('lib/l10n/intl_en.arb')) as Map;
        final ru = jsonDecode(_read('lib/l10n/intl_ru.arb')) as Map;
        for (final key in [
          'deleteCompanyViaSupport',
          'deleteCompanyViaSupportDescription',
          'deleteCompanyViaSupportConfirm',
          'deleteCompanyRequestDraft',
        ]) {
          expect(en.containsKey(key), isTrue, reason: '$key нет в intl_en.arb');
          expect(ru.containsKey(key), isTrue, reason: '$key нет в intl_ru.arb');
          expect(
            RegExp('[а-яА-ЯёЁ]').hasMatch(ru[key] as String),
            isTrue,
            reason: '$key в intl_ru.arb не переведён',
          );
          expect(
            key.contains('deleteChat'),
            isFalse,
            reason:
                '$key: подстрока deleteChat ломает source-scan AC-8 RL-leave',
          );
        }
        expect(
          (ru['deleteCompanyViaSupport'] as String).contains('через поддержку'),
          isTrue,
          reason: 'голое «Удалить» зарезервировано за необратимым forget()',
        );
      },
    );

    test('подсказка композера — «Новый пост» только в канале', () {
      final row = _normalize(_read('lib/pages/chat/chat_input_row.dart'));
      expect(
        row.contains(
          _normalize('''
hintText: controller.room.isChannel
    ? L10n.of(context).channelNewPostHint
    : L10n.of(context).writeAMessage'''),
        ),
        isTrue,
        reason:
            'hintText должен быть ровно '
            'controller.room.isChannel ? channelNewPostHint : writeAMessage',
      );
    });

    test('описание — «Описание канала» только в канале', () {
      final view = _normalize(
        _read('lib/pages/chat_details/chat_details_view.dart'),
      );
      expect(
        view.contains(
          _normalize('''
Text(
  room.isChannel
      ? L10n.of(context).channelDescription
      : isAiDm
      ? L10n.of(context).description
      : L10n.of(context).chatDescription'''),
        ),
        isTrue,
        reason:
            'заголовок описания должен быть ровно '
            'room.isChannel ? channelDescription : isAiDm ? description : chatDescription',
      );
      expect(
        view.contains(
          _normalize('''
tooltip: room.isChannel
    ? L10n.of(context).setChannelDescription
    : L10n.of(context).setChatDescription'''),
        ),
        isTrue,
        reason:
            'tooltip кнопки правки должен быть ровно '
            'room.isChannel ? setChannelDescription : setChatDescription',
      );
      expect(
        view.contains(
          _normalize('''
text: room.topic.isEmpty
    ? room.isChannel
          ? L10n.of(context).noChannelDescriptionYet
          : L10n.of(context).noChatDescriptionYet
    : room.topic'''),
        ),
        isTrue,
        reason:
            'плейсхолдер пустого описания должен быть ровно '
            'room.isChannel ? noChannelDescriptionYet : noChatDescriptionYet',
      );
    });

    test('права — «Права в канале» только в канале', () {
      final view = _normalize(
        _read('lib/pages/chat_details/chat_details_view.dart'),
      );
      expect(
        view.contains(
          _normalize('''
ListTile(
  title: Text(
    room.isChannel
        ? L10n.of(context).channelPermissions
        : L10n.of(context).chatPermissions'''),
        ),
        isTrue,
        reason:
            'пункт прав в деталях должен быть ровно '
            'room.isChannel ? channelPermissions : chatPermissions',
      );
    });

    test('выход участника — «Покинул канал» только в канале', () {
      final view = _normalize(
        _read('lib/pages/chat_details/participant_list_item.dart'),
      );
      expect(
        view.contains(
          _normalize('''
Membership.leave => user.room.isChannel
    ? L10n.of(context).leftTheChannel
    : L10n.of(context).leftTheChat'''),
        ),
        isTrue,
        reason:
            'бейдж membership должен быть ровно '
            'user.room.isChannel ? leftTheChannel : leftTheChat',
      );
    });

    test('пункт «Детали чата» в меню — «Детали канала» только в канале', () {
      final menu = _normalize(
        _read('lib/widgets/chat_settings_popup_menu.dart'),
      );
      expect(
        menu.contains(
          _normalize('''
Text(
  widget.room.isChannel
      ? L10n.of(context).channelDetails
      : L10n.of(context).chatDetails'''),
        ),
        isTrue,
        reason:
            'пункт меню «детали» должен быть ровно '
            'widget.room.isChannel ? channelDetails : chatDetails',
      );
    });

    test('настройки прав чата — «Права в канале» только в канале', () {
      final view = _normalize(
        _read(
          'lib/pages/chat_permissions_settings/chat_permissions_settings_view.dart',
        ),
      );
      expect(
        view.contains(
          _normalize('''
title: Text(
  appBarRoom != null && appBarRoom.isChannel
      ? L10n.of(context).channelPermissions
      : L10n.of(context).chatPermissions'''),
        ),
        isTrue,
        reason:
            'заголовок AppBar должен быть ровно '
            'appBarRoom != null && appBarRoom.isChannel ? channelPermissions : chatPermissions',
      );
      expect(
        view.contains(
          _normalize('''
ListTile(
  title: Text(
    room.isChannel
        ? L10n.of(context).channelPermissions
        : L10n.of(context).chatPermissions'''),
        ),
        isTrue,
        reason:
            'заголовок секции должен быть ровно '
            'room.isChannel ? channelPermissions : chatPermissions',
      );
      expect(
        view.contains(
          _normalize('''
child: Text(
  room.isChannel
      ? L10n.of(context).channelPermissionsDescription
      : L10n.of(context).chatPermissionsDescription'''),
        ),
        isTrue,
        reason:
            'описание секции должно быть ровно '
            'room.isChannel ? channelPermissionsDescription : chatPermissionsDescription',
      );
    });

    test('меню участника — «Права в канале» только в канале', () {
      // Ветвление живёт не в тернарнике виджета, а в чистой функции
      // scopedMemberActionLabel (member_action_scope.dart): к паре
      // chat/channel добавились company и space, тернарник не вмещал их.
      // Сама логика выбора покрыта юнитом
      // test/widgets/member_actions_popup_menu_button_test.dart — здесь
      // сверяем только, что виджет отдаёт функции ВСЕ четыре подписи в
      // правильном порядке (перепутанный порядок вернул бы «права в
      // канале» обычному чату — тот самый регресс, ради которого тест жив).
      final view = _normalize(
        _read('lib/widgets/member_actions_popup_menu_button.dart'),
      );
      expect(
        view.contains(
          _normalize('''
scoped(
  L10n.of(context).chatPermissions,
  L10n.of(context).channelPermissions,
  L10n.of(context).companyPermissions,
  L10n.of(context).spacePermissions,
)'''),
        ),
        isTrue,
        reason:
            'подписи роли должны идти в порядке параметров scoped(): '
            'chat, channel, company, space',
      );
    });

    test('диалог выбора уровня доступа — «Права в канале» через isChannel', () {
      final dialog = _normalize(
        _read('lib/widgets/permission_slider_dialog.dart'),
      );
      expect(
        dialog.contains(
          _normalize('''
child: Text(
  isChannel
      ? L10n.of(context).channelPermissions
      : L10n.of(context).chatPermissions'''),
        ),
        isTrue,
        reason:
            'заголовок диалога должен быть ровно '
            'isChannel ? channelPermissions : chatPermissions',
      );
    });
  });
}
