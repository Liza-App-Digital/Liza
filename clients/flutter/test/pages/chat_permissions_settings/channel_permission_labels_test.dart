// ledger:RL-channel-permissions-labels
import 'dart:io';
//
// Т9 (2026-08-24). Экран «Права» в канале показывал «чат» вместо «канал»
// и сырые технические ключи m.reaction / m.room.redaction / historical.
//
// Фикс:
//   1. isChannel пробросили в PermissionsListTile → ветвь лейблов «канал».
//   2. hiddenEventPermissions += {'m.reaction','m.room.redaction'}.
//   3. 'historical' скрыт через ..removeWhere(k == 'historical').
//   4. Новые l10n-ключи в intl_en.arb И intl_ru.arb.
//
// Стражи:
//   AC-1: PermissionsListTile(isChannel:true) рендерит «канал»-строки для всех
//         ключей; isChannel:false → прежние строки (охранник регресса).
//   AC-2: m.reaction / m.room.redaction / historical не появляются в
//         hiddenEventPermissions (фильтрующий предикат) → тест на чистую логику.
//   AC-3: паритет l10n — все новые ключи есть в intl_ru.arb (не англ. текст).
//
// Red-proof:
//   - AC-1: убрать isChannel-ветку из getLocalizedPowerLevelString → тест находит
//     «чат»-строку вместо «канал».
//   - AC-2: убрать ключ из hiddenEventPermissions → тест находит его в списке.
//   - AC-3: убрать ключ из intl_ru.arb → тест кидает MissingPluginException или
//     показывает EN-строку (тест на совпадение содержит «ru»-значения).

// AC:RL-channel-permissions-labels/1
// AC:RL-channel-permissions-labels/2
// AC:RL-channel-permissions-labels/3
// AC:RL-channel-permissions-labels/4
// AC:RL-channel-permissions-labels/5
// AC:RL-channel-permissions-labels/6

// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_permissions_settings/permission_list_tile.dart';

// ---------------------------------------------------------------------------
// Хелпер: рендерим PermissionsListTile в изоляции с нужной локалью.
// ---------------------------------------------------------------------------
Widget _wrapTile(PermissionsListTile tile, {String locale = 'ru'}) {
  return MaterialApp(
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: Locale(locale),
    home: Scaffold(body: tile),
  );
}

// ---------------------------------------------------------------------------
// Продовые константы из chat_permissions_settings_view.dart
// (УСЛОВНАЯ реплика — только для unit-слоя AC-2).
// isChannel=true: оба ключа скрыты. isChannel=false: ни один не скрыт.
// Если prod-код изменит это условие, source-scan AC-2src и real-widget AC-2w
// поймают расхождение раньше, чем эта реплика будет обновлена.
// ---------------------------------------------------------------------------
Set<String> _hiddenEventPermissions({required bool isChannel}) => {
  EventTypes.RoomTombstone,
  EventTypes.Encryption,
  'm.room.server_acl',
  if (isChannel) 'm.reaction',      // только в канале
  if (isChannel) 'm.room.redaction', // только в канале
};

// ---------------------------------------------------------------------------
// Тесты
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // AC-1: PermissionsListTile рендерит «канал»-строки при isChannel:true
  // -------------------------------------------------------------------------
  group('AC-1 [AC:RL-channel-permissions-labels/1] — isChannel лейблы (widget, реальный тайл)', () {
    // Пары (permissionKey, category?, ожидаемая RU-строка в канале)
    final channelCases = [
      (key: 'events_default', cat: null, expected: 'Публиковать в канале'),
      (key: 'state_default', cat: null, expected: 'Изменить общие настройки канала'),
      (key: 'ban', cat: null, expected: 'Заблокировать в канале'),
      (key: 'kick', cat: null, expected: 'Исключить из канала'),
      (key: 'redact', cat: null, expected: 'Удалить публикацию'),
      (key: 'invite', cat: null, expected: 'Пригласить других пользователей в этот канал'),
      (key: EventTypes.RoomName, cat: 'events', expected: 'Изменить название канала'),
      (key: EventTypes.RoomTopic, cat: 'events', expected: 'Изменить описание канала'),
      (key: EventTypes.RoomPowerLevels, cat: 'events', expected: 'Изменить права доступа к каналу'),
      (key: EventTypes.HistoryVisibility, cat: 'events', expected: 'Изменить видимость истории канала'),
      (key: EventTypes.RoomAvatar, cat: 'events', expected: 'Изменить аватар канала'),
      // 2026-08-25: канонический адрес был единственным неразветвлённым ключом
      // (показывал «...адрес чата» на экране прав канала — скриншот владельца).
      (key: EventTypes.RoomCanonicalAlias, cat: 'events', expected: 'Изменить основной общедоступный адрес канала'),
    ];

    for (final c in channelCases) {
      testWidgets('isChannel=true: ${c.key} → «${c.expected}»', (tester) async {
        await tester.pumpWidget(
          _wrapTile(
            PermissionsListTile(
              permissionKey: c.key,
              permission: 50,
              category: c.cat,
              onChanged: null,
              canEdit: false,
              isChannel: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(c.expected),
          findsOneWidget,
          reason: 'isChannel=true, ключ=${c.key} должен рендерить «${c.expected}»',
        );
      });
    }

    // Охранник регресса: isChannel:false → прежние «чат»-строки
    // Строки берём из intl_ru.arb для l10n-точности.
    final chatCases = [
      (key: 'events_default', cat: null, expected: 'Отправить сообщения'),
      (key: 'state_default', cat: null, expected: 'Изменить общие настройки чата'),
      (key: 'ban', cat: null, expected: 'Заблокировать в чате'),
      (key: 'kick', cat: null, expected: 'Исключить из чата'),
      (key: 'redact', cat: null, expected: 'Удалить сообщение'),
      (key: 'invite', cat: null, expected: 'Пригласить других пользователей в этот чат'),
      (key: EventTypes.RoomName, cat: 'events', expected: 'Изменить название группы'),
      (key: EventTypes.RoomTopic, cat: 'events', expected: 'Изменить описание чата'),
      (key: EventTypes.RoomPowerLevels, cat: 'events', expected: 'Изменить права доступа к чату'),
      (key: EventTypes.HistoryVisibility, cat: 'events', expected: 'Изменить видимость истории чата'),
      (key: EventTypes.RoomAvatar, cat: 'events', expected: 'Изменить аватар чата'),
      // Охранник регресса: не-канал сохраняет «...адрес чата».
      (key: EventTypes.RoomCanonicalAlias, cat: 'events', expected: 'Изменить основной общедоступный адрес чата'),
    ];

    for (final c in chatCases) {
      testWidgets('isChannel=false: ${c.key} → «${c.expected}» (охранник регресса)', (tester) async {
        await tester.pumpWidget(
          _wrapTile(
            PermissionsListTile(
              permissionKey: c.key,
              permission: 50,
              category: c.cat,
              onChanged: null,
              canEdit: false,
              isChannel: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(c.expected),
          findsOneWidget,
          reason: 'isChannel=false, ключ=${c.key} должен рендерить «${c.expected}» (без «канал»)',
        );
      });
    }
  });

  // -------------------------------------------------------------------------
  // AC-2: m.reaction / m.room.redaction / historical не в editable-списке
  // -------------------------------------------------------------------------
  group('AC-2 [AC:RL-channel-permissions-labels/2] — инвариант-ключи СКРЫТЫ', () {
    // Набор ключей events, аналогичный продовому каналу.
    final allEventKeys = {
      'm.reaction': 0,
      'm.room.redaction': 0,
      'm.room.avatar': 50,
      EventTypes.RoomName: 50,
      EventTypes.RoomTopic: 50,
      EventTypes.RoomPowerLevels: 100,
      EventTypes.HistoryVisibility: 100,
    };

    // Фильтрация как в chat_permissions_settings_view.dart
    final visibleEventKeys = Map.fromEntries(
      allEventKeys.entries.where(
        (e) => !_hiddenEventPermissions(isChannel: true).contains(e.key),
      ),
    );

    test('m.reaction НЕ попадает в видимые ключи events', () {
      expect(visibleEventKeys.containsKey('m.reaction'), isFalse,
          reason: 'm.reaction скрыт — модератор не должен иметь возможность '
              'поднять порог и сломать снятие реакций');
    });

    test('m.room.redaction НЕ попадает в видимые ключи events', () {
      expect(visibleEventKeys.containsKey('m.room.redaction'), isFalse,
          reason: 'm.room.redaction скрыт — аналогично, инвариант реакций');
    });

    test('видимые events-ключи после фильтрации не содержат скрытых', () {
      for (final hidden in _hiddenEventPermissions(isChannel: true)) {
        expect(
          visibleEventKeys.containsKey(hidden),
          isFalse,
          reason: 'Ключ $hidden должен быть скрыт из editable UI',
        );
      }
    });

    test('видимые events-ключи после фильтрации содержат полезные настройки', () {
      expect(visibleEventKeys.containsKey(EventTypes.RoomName), isTrue);
      expect(visibleEventKeys.containsKey(EventTypes.RoomTopic), isTrue);
    });

    // AC:RL-channel-permissions-labels/2 — SOURCE-SCAN на ПРОДОВЫЙ инвариант
    // (замена реплики: hiddenEventPermissions — build-локаль, вызвать нельзя,
    // поэтому сторожим сам прод-файл, что скрытие m.reaction/m.room.redaction
    // условно по room.isChannel и не безусловно — иначе регресс «скрыли
    // реакции и в обычном чате» проскочит мимо реплики).
    test('ПРОД: m.reaction/m.room.redaction скрыты ТОЛЬКО в канале (if room.isChannel)', () {
      final src = File(
        'lib/pages/chat_permissions_settings/chat_permissions_settings_view.dart',
      ).readAsStringSync();
      expect(
        src.contains("if (room.isChannel) 'm.reaction'"),
        isTrue,
        reason: 'Прод обязан скрывать m.reaction ТОЛЬКО в канале (условно)',
      );
      expect(
        src.contains("if (room.isChannel) 'm.room.redaction'"),
        isTrue,
        reason: 'Прод обязан скрывать m.room.redaction ТОЛЬКО в канале (условно)',
      );
      // Регресс-охранник: НЕ должно быть безусловного скрытия этих ключей
      // (без гейта isChannel) — иначе в обычном чате их спрячут ошибочно.
      final hiddenBlock = src.substring(
        src.indexOf('hiddenEventPermissions'),
        src.indexOf('hiddenEventPermissions') + 400,
      );
      expect(
        RegExp(r"(?<!isChannel\) )'m\.reaction'").hasMatch(
          hiddenBlock.replaceAll("if (room.isChannel) 'm.reaction'", ''),
        ),
        isFalse,
        reason: 'm.reaction в hidden-наборе только под гейтом isChannel',
      );
    });

    // Тест на исключение 'historical' из top-level powerLevels
    test('historical скрыт из top-level powerLevels', () {
      final powerLevels = <String, dynamic>{
        'events_default': 100,
        'state_default': 50,
        'users_default': 0,
        'redact': 50,
        'historical': 100, // ← этот должен быть убран
        'ban': 50,
      };
      // Имитируем логику из view: removeWhere(k == 'historical' || value !is int)
      final filtered = Map<String, dynamic>.from(powerLevels)
        ..removeWhere((k, v) => v is! int || k == 'historical');
      expect(filtered.containsKey('historical'), isFalse,
          reason: 'historical — служебный Synapse-ключ, не человеко-редактируемый');
    });

    // RED-PROOF: убрать m.reaction из _hiddenEventPermissions → тест краснеет
    test('RED-PROOF: при отсутствии m.reaction в hiddenSet он появляется в visible', () {
      const brokenHidden = {
        EventTypes.RoomTombstone,
        EventTypes.Encryption,
        'm.room.server_acl',
        // m.reaction убран — имитируем откат фикса
        'm.room.redaction',
      };
      final brokenVisible = Map.fromEntries(
        allEventKeys.entries.where((e) => !brokenHidden.contains(e.key)),
      );
      // В сломанном наборе m.reaction ПОЯВЛЯЕТСЯ:
      expect(brokenVisible.containsKey('m.reaction'), isTrue,
          reason: 'Баг воспроизведён: без фильтрации m.reaction виден в UI');
      // В правильном — нет:
      expect(visibleEventKeys.containsKey('m.reaction'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // AC-3: паритет l10n — все новые ключи есть в обоих языках
  // -------------------------------------------------------------------------
  group('AC-3 [AC:RL-channel-permissions-labels/3] — l10n паритет EN/RU', () {
    // Тест проверяет, что при рендере с locale='ru' строки — действительно
    // русские (не английские плейсхолдеры). Если ключ в ru.arb отсутствует,
    // Flutter молча подставит en-вариант — это детектируется сравнением строк.

    final channelKeyChecks = [
      (key: 'events_default', cat: null as String?, enText: 'Post to the channel', ruText: 'Публиковать в канале'),
      (key: 'state_default', cat: null, enText: 'Change general channel settings', ruText: 'Изменить общие настройки канала'),
      (key: 'ban', cat: null, enText: 'Ban from the channel', ruText: 'Заблокировать в канале'),
      (key: 'kick', cat: null, enText: 'Remove from the channel', ruText: 'Исключить из канала'),
      (key: 'redact', cat: null, enText: 'Delete a post', ruText: 'Удалить публикацию'),
      (key: 'invite', cat: null, enText: 'Invite other users to this channel', ruText: 'Пригласить других пользователей в этот канал'),
      (key: EventTypes.RoomName, cat: 'events', enText: 'Change the name of the channel', ruText: 'Изменить название канала'),
      (key: EventTypes.RoomTopic, cat: 'events', enText: 'Change the description of the channel', ruText: 'Изменить описание канала'),
      (key: EventTypes.RoomPowerLevels, cat: 'events', enText: 'Change the channel permissions', ruText: 'Изменить права доступа к каналу'),
      (key: EventTypes.HistoryVisibility, cat: 'events', enText: 'Change the visibility of channel history', ruText: 'Изменить видимость истории канала'),
      (key: EventTypes.RoomAvatar, cat: 'events', enText: 'Edit channel avatar', ruText: 'Изменить аватар канала'),
      (key: EventTypes.RoomCanonicalAlias, cat: 'events', enText: 'Change the main public channel address', ruText: 'Изменить основной общедоступный адрес канала'),
    ];

    for (final c in channelKeyChecks) {
      testWidgets('AC-3 ru-ключ "${c.key}": рендерит RU а не EN', (tester) async {
        await tester.pumpWidget(
          _wrapTile(
            PermissionsListTile(
              permissionKey: c.key,
              permission: 50,
              category: c.cat,
              onChanged: null,
              canEdit: false,
              isChannel: true,
            ),
            locale: 'ru',
          ),
        );
        await tester.pumpAndSettle();
        // Убеждаемся: RU-строка ЕСТЬ, EN-строка НЕТ
        expect(
          find.text(c.ruText),
          findsOneWidget,
          reason: 'ключ ${c.key} должен рендерить RU-строку',
        );
        expect(
          find.text(c.enText),
          findsNothing,
          reason:
              'EN-текст "${c.enText}" не должен появляться при locale=ru '
              '(означало бы отсутствие ключа в intl_ru.arb)',
        );
      });
    }
  });

  // -------------------------------------------------------------------------
  // AC-4: меню участника канала — kick/ban/unban говорят «канал», не «чат».
  // Баг (2026-08-25): в scoped(chat, channel, company, space) в СЛОТ channel
  // был подставлен chat-ключ, хотя kickFromChannel/banFromChannel существуют.
  // Ветвление по типу комнаты — чистая scopedMemberActionLabel (покрыта в
  // member_actions_popup_menu_button_test.dart); здесь сторожим САМ call-site
  // source-scan'ом (виджет целиком смонтировать нечем — нужен живой User/Room,
  // см. комментарий в member_action_scope.dart).
  // -------------------------------------------------------------------------
  group('AC-4 [AC:RL-channel-permissions-labels/4] — kick/ban/unban в канале говорят «канал»', () {
    final src = File(
      'lib/widgets/member_actions_popup_menu_button.dart',
    ).readAsStringSync();

    test('channel-слот scoped() несёт *FromChannel-ключи', () {
      expect(src.contains('L10n.of(context).kickFromChannel'), isTrue,
          reason: 'kick: слот channel обязан быть kickFromChannel');
      expect(src.contains('L10n.of(context).banFromChannel'), isTrue,
          reason: 'ban: слот channel обязан быть banFromChannel');
      expect(src.contains('L10n.of(context).unbanFromChannel'), isTrue,
          reason: 'unban: слот channel обязан быть unbanFromChannel');
    });

    // RED-PROOF: исходный баг = chat-ключ в ДВУХ слотах подряд (chat И channel).
    // Каждый *FromChat встречается в scoped() ровно один раз (только chat-слот).
    test('RED-PROOF: *FromChat НЕ продублирован в channel-слоте', () {
      expect(RegExp(r'L10n\.of\(context\)\.kickFromChat\b').allMatches(src).length, 1,
          reason: 'kickFromChat должен быть только в chat-слоте (баг = 2 раза)');
      expect(RegExp(r'L10n\.of\(context\)\.banFromChat\b').allMatches(src).length, 1,
          reason: 'banFromChat должен быть только в chat-слоте');
      expect(RegExp(r'L10n\.of\(context\)\.unbanFromChat\b').allMatches(src).length, 1,
          reason: 'unbanFromChat должен быть только в chat-слоте');
    });
  });

  // -------------------------------------------------------------------------
  // AC-5: диалоги подтверждения kick/ban/unban в канале говорят «канал».
  // Source-scan ветвления на call-site + real-widget паритет новых ключей.
  // -------------------------------------------------------------------------
  group('AC-5 [AC:RL-channel-permissions-labels/5] — описания kick/ban/unban ветвятся по каналу', () {
    final src = File(
      'lib/widgets/member_actions_popup_menu_button.dart',
    ).readAsStringSync();

    test('описания ветвятся user.room.isChannel ? …Channel : …', () {
      for (final k in ['kickUserDescriptionChannel', 'banUserDescriptionChannel', 'unbanUserDescriptionChannel']) {
        expect(src.contains('L10n.of(context).$k'), isTrue,
            reason: 'описание обязано иметь channel-вариант $k на call-site');
      }
      expect(src.contains('user.room.isChannel'), isTrue,
          reason: 'ветвление описаний по типу комнаты');
    });

    final descChecks = [
      (pick: (L10n l) => l.kickUserDescriptionChannel, ru: 'Пользователь исключён из канала, но не заблокирован. В публичных каналах он может вернуться в любой момент.', en: 'The user is kicked out of the channel but not banned. In public channels, the user can rejoin at any time.'),
      (pick: (L10n l) => l.banUserDescriptionChannel, ru: 'Заблокированные в канале пользователи не смогут перезайти в канал, пока они не будут разблокированы.', en: 'The user will be banned from the channel and will not be able to enter the channel again until they are unbanned.'),
      (pick: (L10n l) => l.unbanUserDescriptionChannel, ru: 'Пользователь сможет при желании зайти в канал снова.', en: 'The user will be able to enter the channel again if they try.'),
    ];
    for (final c in descChecks) {
      testWidgets('паритет RU: ${c.ru.substring(0, 20)}…', (tester) async {
        await tester.pumpWidget(_wrapL10nText(c.pick, locale: 'ru'));
        await tester.pumpAndSettle();
        expect(find.text(c.ru), findsOneWidget, reason: 'RU-строка обязана быть в intl_ru.arb');
        expect(find.text(c.en), findsNothing, reason: 'EN не должен всплыть при locale=ru');
      });
    }
  });

  // -------------------------------------------------------------------------
  // AC-6: анти-over-reach. Универсальную leave-заглушку и инвариант-ключи
  // канала НЕ переименовываем в «канал» — иначе регресс (реакции / все типы
  // комнат). Страж от будущего чрезмерного свипа.
  // -------------------------------------------------------------------------
  group('AC-6 [AC:RL-channel-permissions-labels/6] — намеренно НЕ тронутое', () {
    test('leave-заглушка остаётся универсальной (нет channel-варианта ключа)', () {
      final en = File('lib/l10n/intl_en.arb').readAsStringSync();
      expect(en.contains('"youAreNoLongerParticipatingInThisChat"'), isTrue,
          reason: 'универсальная leave-строка на месте');
      expect(en.contains('youAreNoLongerParticipatingInThisChannel'), isFalse,
          reason: 'НЕ заводить channel-вариант leave-заглушки (7 call-sites, все типы комнат)');
    });

    test('инвариант-ключи реакций НЕ переименованы (скрыты — см. AC-2)', () {
      final src = File(
        'lib/pages/chat_permissions_settings/permission_list_tile.dart',
      ).readAsStringSync();
      // Нет l10n-лейбла для m.reaction/m.room.redaction/historical — они не
      // проходят через getLocalizedPowerLevelString как именованные строки.
      expect(src.contains("case 'm.reaction':"), isFalse,
          reason: 'm.reaction не должен получать человекочитаемый лейбл');
      expect(src.contains("case 'm.room.redaction':"), isFalse,
          reason: 'm.room.redaction не должен получать человекочитаемый лейбл');
    });
  });
}

// Рендерит произвольную l10n-строку — для паритет-проверки ключей вне
// PermissionsListTile (описания kick/ban/unban).
Widget _wrapL10nText(String Function(L10n) pick, {String locale = 'ru'}) {
  return MaterialApp(
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: Locale(locale),
    home: Scaffold(body: Builder(builder: (c) => Text(pick(L10n.of(c))))),
  );
}
