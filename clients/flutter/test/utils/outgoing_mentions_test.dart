// Страж реестра регрессии: ledger:RL-outgoing-mentions-intent (см. tests/registry/).
//
// C1 чек-листа (2026-11-24): Synapse ≥1.164 (MSC4210) удаляет легаси-подсветку по
// имени — подсветку даёт ТОЛЬКО явный m.mentions. Клиент обязан: пересылку и правку
// слать с `{}` (не пинговать повторно), голосовой ответ — с автором, а локальный
// эвалюатор пуш-правил — понимать `content.m\.mentions.*`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/forwarded_content_builder.dart';
import 'package:liza/utils/liza_client.dart';
import 'package:liza/utils/push_rule_defaults.dart';
import 'package:liza/utils/typed_mention_resolver.dart';
import 'test_client.dart';

const _me = '@alice:example.invalid';
const _bob = '@bob:example.invalid';

/// Фрагмент дефолтного набора Synapse (base_rules.rs), в порядке override.
Map<String, Object?> _pushRules({bool mentionsOnlyRoom = false}) => {
  'global': {
    'override': [
      {
        'rule_id': '.m.rule.suppress_notices',
        'default': true,
        'enabled': true,
        'conditions': [
          {
            'kind': 'event_match',
            'key': 'content.msgtype',
            'pattern': 'm.notice',
          },
        ],
        'actions': [],
      },
      {
        'rule_id': '.m.rule.is_user_mention',
        'default': true,
        'enabled': true,
        'conditions': [
          {
            'kind': 'event_property_contains',
            'key': r'content.m\.mentions.user_ids',
            'value': _me,
          },
        ],
        'actions': [
          'notify',
          {'set_tweak': 'sound', 'value': 'default'},
          {'set_tweak': 'highlight'},
        ],
      },
      {
        'rule_id': '.m.rule.is_room_mention',
        'default': true,
        'enabled': true,
        'conditions': [
          {
            'kind': 'event_property_is',
            'key': r'content.m\.mentions.room',
            'value': true,
          },
        ],
        'actions': [
          'notify',
          {'set_tweak': 'highlight'},
        ],
      },
      {
        'rule_id': '.m.rule.suppress_edits',
        'default': true,
        'enabled': true,
        'conditions': [
          {
            'kind': 'event_property_is',
            'key': r'content.m\.relates_to.rel_type',
            'value': 'm.replace',
          },
        ],
        'actions': [],
      },
    ],
    'room': [
      if (mentionsOnlyRoom)
        {
          'rule_id': '!room:example.invalid',
          'default': false,
          'enabled': true,
          'actions': ['dont_notify'],
        },
    ],
    'underride': [
      {
        'rule_id': '.m.rule.message',
        'default': true,
        'enabled': true,
        'conditions': [
          {'kind': 'event_match', 'key': 'type', 'pattern': 'm.room.message'},
        ],
        'actions': ['notify'],
      },
    ],
  },
};

Event _event(Room room, Map<String, Object?> content) => Event(
  content: content,
  type: EventTypes.Message,
  eventId: r'$e',
  senderId: _bob,
  originServerTs: DateTime.now(),
  room: room,
);

void main() {
  late Client client;
  late Room room;

  setUpAll(() async {
    client = await prepareTestClient(loggedIn: true, userId: _me);
    room = Room(id: '!room:example.invalid', client: client);
  });

  group('LizaClient: локальный эвалюатор понимает m\\.mentions', () {
    PushruleEvaluator fixed(Map<String, Object?> rules) =>
        PushruleEvaluator.fromRuleset(intentionalMentionsRuleset(rules));

    test('ключи условий раскрыты, прочие поля нетронуты', () {
      final set = intentionalMentionsRuleset(_pushRules());
      final keys = [
        for (final r in set.override!)
          for (final c in r.conditions ?? const <PushCondition>[]) c.key,
      ];
      expect(keys, contains('content.m.mentions.user_ids'));
      expect(keys, contains('content.m.relates_to.rel_type'));
      expect(keys.where((k) => k != null && k.contains(r'\.')), isEmpty);
      expect(set.override!.length, 4);
      expect(intentionalMentionsRuleset(null).override, isNull);
    });

    // AC:RL-outgoing-mentions-intent/9 — матрица «режим чата × событие»
    for (final mentionsOnly in [false, true]) {
      final mode = mentionsOnly ? 'только упоминания' : 'все сообщения';
      test('$mode: m.mentions.user_ids=[я] → highlight', () {
        final a = fixed(_pushRules(mentionsOnlyRoom: mentionsOnly)).match(
          _event(room, {
            'msgtype': 'm.text',
            'body': 'привет',
            'm.mentions': {
              'user_ids': [_me],
            },
          }),
        );
        expect(a.notify, isTrue);
        expect(a.highlight, isTrue);
      });

      test('$mode: m.mentions.room=true → highlight', () {
        final a = fixed(_pushRules(mentionsOnlyRoom: mentionsOnly)).match(
          _event(room, {
            'msgtype': 'm.text',
            'body': '@room',
            'm.mentions': {'room': true},
          }),
        );
        expect(a.highlight, isTrue);
      });

      test('$mode: правка с упоминанием меня внутри → тишина', () {
        final a = fixed(_pushRules(mentionsOnlyRoom: mentionsOnly)).match(
          _event(room, {
            'msgtype': 'm.text',
            'body': '* x',
            'm.mentions': <String, Object?>{},
            'm.new_content': {
              'msgtype': 'm.text',
              'body': 'x',
              'm.mentions': <String, Object?>{},
            },
            'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$o'},
          }),
        );
        expect(a.notify, isFalse);
        expect(a.highlight, isFalse);
      });

      test('$mode: m.mentions про другого → без highlight', () {
        final a = fixed(_pushRules(mentionsOnlyRoom: mentionsOnly)).match(
          _event(room, {
            'msgtype': 'm.text',
            'body': 'x',
            'm.mentions': {
              'user_ids': ['@carol:example.invalid'],
            },
          }),
        );
        expect(a.highlight, isFalse);
        expect(a.notify, !mentionsOnly);
      });
    }

    test('red-proof: сырой эвалюатор SDK упоминание НЕ видит', () {
      final raw = PushruleEvaluator.fromRuleset(
        PushRuleSet.fromJson(
          (_pushRules()['global'] as Map).cast<String, Object?>(),
        ),
      );
      final a = raw.match(
        _event(room, {
          'msgtype': 'm.text',
          'body': 'x',
          'm.mentions': {
            'user_ids': [_me],
          },
        }),
      );
      expect(a.highlight, isFalse);
    });
  });

  group('исходящие m.mentions', () {
    // AC:RL-outgoing-mentions-intent/6
    test('пересылка → {} и без m.new_content (вкл. чужой room:true)', () async {
      final src = _event(room, {
        'msgtype': 'm.text',
        'body': '@room всем',
        'm.mentions': {
          'room': true,
          'user_ids': [_me],
        },
        'm.new_content': {'msgtype': 'm.text', 'body': 'старое'},
        'm.relates_to': {
          'm.in_reply_to': {'event_id': r'$x'},
        },
      });
      final out = await buildForwardedContent(src);
      expect(out['m.mentions'], <String, Object?>{});
      expect(out.containsKey('m.new_content'), isFalse);
      expect(out.containsKey('m.relates_to'), isFalse);
      expect(src.content['m.mentions'], isNotEmpty);
    });

    // AC:RL-outgoing-mentions-intent/8
    test(
      'голосовой ответ → автор в user_ids; ответ себе / без ответа → без ключа',
      () {
        expect(
          TypedMentionResolver.replyMentionsExtra(
            _event(room, {'msgtype': 'm.text', 'body': 'x'}),
            _me,
          ),
          {
            'm.mentions': {
              'user_ids': [_bob],
            },
          },
        );
        final mine = Event(
          content: {'msgtype': 'm.text', 'body': 'x'},
          type: EventTypes.Message,
          eventId: r'$mine',
          senderId: _me,
          originServerTs: DateTime.now(),
          room: room,
        );
        expect(TypedMentionResolver.replyMentionsExtra(mine, _me), isEmpty);
        expect(TypedMentionResolver.replyMentionsExtra(null, _me), isEmpty);
      },
    );

    // AC:RL-outgoing-mentions-intent/7 — мультикейс: пилюля, без, @room
    for (final body in [
      'обычный текст',
      'привет @[Боб Бобов] глянь',
      '@room всем',
      'полный mxid $_bob',
    ]) {
      test('правка «$body» уходит с {} наверху и в m.new_content', () async {
        final sendRoom = Room(id: '!localpart:server.abc', client: client);
        FakeMatrixApi.calledEndpoints.clear();
        await sendRoom.sendEvent(
          TypedMentionResolver.editTextContent(body),
          txid: 'testtxid',
          editEventId: r'$orig',
        );
        final sent = FakeMatrixApi.calledEndpoints.entries
            .firstWhere((e) => e.key.contains('/send/m.room.message/testtxid'))
            .value
            .last;
        final json = jsonDecode(sent as String) as Map<String, Object?>;
        expect(json['m.mentions'], <String, Object?>{});
        expect(
          (json['m.new_content'] as Map)['m.mentions'],
          <String, Object?>{},
        );
        expect(json['body'], '* $body');
        expect((json['m.relates_to'] as Map)['rel_type'], 'm.replace');
      });
    }
  });

  test('прод-клиент создаётся как LizaClient (иначе эвалюатор сырой SDK)', () {
    final src = File('lib/utils/client_manager.dart').readAsStringSync();
    expect(src, contains('final client = LizaClient('));
  });

  group('PushRuleDefaults после MSC4210', () {
    test('404 на легаси-правило не обрывает сброс остальных', () async {
      final calls = <String>[];
      await PushRuleDefaults.resetToDefaults(
        PushRuleDefaults.rules
            .where(
              (r) =>
                  r.ruleId == '.m.rule.contains_display_name' ||
                  r.ruleId == '.m.rule.message',
            )
            .toList(),
        (kind, id, enabled) async {
          calls.add(id);
          if (id == '.m.rule.contains_display_name') {
            throw MatrixException.fromJson({
              'errcode': 'M_NOT_FOUND',
              'error': 'Unknown rule',
            });
          }
        },
      );
      expect(
        calls,
        containsAll(['.m.rule.message', '.m.rule.contains_display_name']),
      );
    });

    test('иная ошибка по-прежнему пробрасывается', () async {
      expect(
        () => PushRuleDefaults.resetToDefaults(
          [PushRuleDefaults.rules.first],
          (kind, id, enabled) async => throw MatrixException.fromJson({
            'errcode': 'M_FORBIDDEN',
            'error': 'no',
          }),
        ),
        throwsA(isA<MatrixException>()),
      );
    });
  });
}
