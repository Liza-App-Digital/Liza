// ledger:RL-push-incident-export
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/utils/apns_push_service.dart';
import 'package:liza/utils/background_push.dart';
import 'package:liza/utils/push_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AC:RL-push-incident-export/9
  test(
    'настоящий native gate сохраняет account/media для событийного экспорта',
    () async {
      final journal = PushJournal.instance;
      journal.resetForTest();
      addTearDown(journal.resetForTest);
      final push = BackgroundPush.clientOnly([]);
      const event = r'$gate-trace-PRIVATE';
      const account = 'Liza-PRIVATE-gate';
      push.markLocallyShown(
        event,
        clientName: account,
        msgtype: 'm.audio',
        isVoice: true,
      );
      final result = await push.nativeBannerGate({
        'event_id': event,
        'client_name': account,
        'content': {'msgtype': 'm.audio', 'voice': true},
      });
      expect(result, NativeBannerGate.suppress);
      final entry = journal.entries.last;
      expect(entry.stage, PushStage.gate);
      expect(entry.eventHash128, PushJournal.hash128(event));
      expect(entry.accountHash128, PushJournal.hash128(account));
      expect(entry.mediaKind, PushMediaKind.voice);
      expect(entry.source, PushObservationSource.apnsPreview);
      expect(entry.relationKind, PushRelationKind.unknown);
      expect(jsonEncode(entry.toJson()), isNot(contains('PRIVATE')));
    },
  );
}
