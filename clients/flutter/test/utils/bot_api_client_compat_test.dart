// ledger:RL-bot-api-client-compat
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/pages/chat_list/chat_list_item.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';

import 'test_client.dart';

void main() {
  group('Bot API — владение', () {
    // AC:RL-bot-api-client-compat/1
    test('точный домен ботов исключён из передачи и выбора преемника', () {
      for (final target in ['@custom:bots.liza.ru', '@liza:company.example']) {
        expect(isServiceAccountId(target), isTrue);
        expect(
          canTransferOwnershipTo(
            ownPowerLevel: 100,
            callerId: '@owner:company.example',
            targetId: target,
            targetPowerLevel: 99,
            targetJoined: true,
            isDirectChat: false,
          ),
          isFalse,
        );
        expect(
          pickOwnerSuccessor([
            OwnerSuccessorCandidate(target, 99),
            const OwnerSuccessorCandidate('@person:company.example', 50),
          ]),
          '@person:company.example',
        );
        expect(
          pickOwnerSuccessor([OwnerSuccessorCandidate(target, 99)]),
          isNull,
        );
      }
      for (final target in [
        '@person:company.example',
        '@custom:bots.liza.ru.example',
        '@custom:other-bots.liza.ru',
      ]) {
        expect(isServiceAccountId(target), isFalse);
        expect(
          canTransferOwnershipTo(
            ownPowerLevel: 100,
            callerId: '@owner:company.example',
            targetId: target,
            targetPowerLevel: 50,
            targetJoined: true,
            isDirectChat: false,
          ),
          isTrue,
        );
        expect(
          pickOwnerSuccessor([OwnerSuccessorCandidate(target, 50)]),
          target,
        );
      }
    });
  });

  group('Bot API — удалённый черновик на реальном SDK', () {
    late Client client;
    late Room room;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init(loadWebConfigFile: false);
      await AppSettings.hideRedactedEvents.setItem(false);
      client = await prepareTestClient(loggedIn: true);
      room = Room(id: '!draft:example.invalid', client: client);
    });

    tearDown(() async => client.dispose(closeDatabase: true));

    Event event({
      String type = EventTypes.Message,
      String? reason = 'com.liza.draft',
      String deletionSender = '@custom:bots.liza.ru',
      String deletionType = EventTypes.Redaction,
      bool redacted = true,
    }) => Event(
      type: type,
      eventId: '\$draft',
      senderId: '@custom:bots.liza.ru',
      originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
      room: room,
      content: redacted
          ? {}
          : {'msgtype': MessageTypes.Notice, 'body': 'Ответ готовится'},
      unsigned: redacted
          ? {
              'redacted_because': {
                'type': deletionType,
                'event_id': '\$deletion',
                'sender': deletionSender,
                'origin_server_ts': 2000,
                'content': {if (reason != null) 'reason': reason},
              },
            }
          : null,
    );

    // AC:RL-bot-api-client-compat/2
    test('self-redaction скрыта из ленты даже по exceptionEventId', () {
      for (final type in [EventTypes.Message, EventTypes.Encrypted]) {
        final draft = event(type: type);
        expect(draft.isRedactedBotDraft, isTrue);
        expect(draft.isVisibleInGui, isFalse);
        expect([draft].filterByVisibleInGui(), isEmpty);
        expect(
          [draft].filterByVisibleInGui(exceptionEventId: draft.eventId),
          isEmpty,
        );
      }
    });

    // AC:RL-bot-api-client-compat/3
    test('превью пропускает черновик; при пустом хвосте возвращает null', () {
      final draft = event();
      final finalMessage = Event(
        type: EventTypes.Message,
        eventId: '\$final',
        senderId: draft.senderId,
        originServerTs: DateTime.fromMillisecondsSinceEpoch(3000),
        room: room,
        content: {'msgtype': MessageTypes.Text, 'body': 'Готовый ответ'},
      );
      expect(previewEventFrom([draft]), isNull);
      expect(previewEventFrom([draft, finalMessage]), same(finalMessage));
    });

    // AC:RL-bot-api-client-compat/4
    test('обычные/чужие удаления и живой notice остаются видимыми', () {
      for (final ordinary in [
        event(reason: null),
        event(reason: 'обычное удаление'),
        event(deletionSender: '@moderator:example.invalid'),
        event(redacted: false),
      ]) {
        expect(ordinary.isRedactedBotDraft, isFalse);
        expect(ordinary.isVisibleInGui, isTrue);
        expect([ordinary].filterByVisibleInGui(), [ordinary]);
        expect(previewEventFrom([ordinary]), same(ordinary));
      }
      expect(event(type: EventTypes.RoomName).isRedactedBotDraft, isFalse);
      expect(
        event(deletionType: EventTypes.Message).isRedactedBotDraft,
        isFalse,
      );
    });
  });
}
