// prod_mmr_media_test.dart — РЕАЛЬНЫЙ клиентский тест против ПРОД-MMR на эмуляторе.
//
// Проверяет, что после cutover (клиентское медиа → MMR → S3) настоящий Matrix-SDK
// клиента Liza на реальном устройстве/эмуляторе:
//   1) СКАЧИВАЕТ медиа через тот же authenticated v1-путь, что и приложение
//      (getContentAuthed → /_matrix/client/v1/media/download), для образцов ВСЕХ
//      эпох (старейшие/июль/дельта/новейшие);
//   2) ДЕКОДИРУЕТ картинку движком Flutter (ui.instantiateImageCodec) → валидное
//      изображение с ненулевыми размерами (то, что рисует mxc_image в ленте);
//   3) UPLOAD→DOWNLOAD round-trip через MMR (durable запись с клиента) — байты сходятся.
//
// БЕЗ OIDC: сессия восстанавливается токеном (--dart-define). Аккаунт и медиа —
// контролируемые (тест-загрузка удаляется на сервере отдельно). Запуск:
//   flutter test integration_test/liza/prod_mmr_media_test.dart -d <emulator> \
//     --dart-define=PROD_TOKEN=... --dart-define=PROD_IMAGE_IDS=id1,id2,...
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const server = 'synapse.liza.laba.prodamus.tech';
  const token = String.fromEnvironment('PROD_TOKEN');
  const imageIds = String.fromEnvironment('PROD_IMAGE_IDS'); // csv image media_ids

  MatrixApi apiFor() => MatrixApi(homeserver: Uri.parse('https://$server'))
    ..accessToken = token;

  testWidgets('ПРОД MMR: клиент скачивает и ДЕКОДИРУЕТ картинки всех эпох',
      (tester) async {
    expect(token.isNotEmpty, true, reason: 'нужен --dart-define=PROD_TOKEN');
    expect(imageIds.isNotEmpty, true, reason: 'нужен --dart-define=PROD_IMAGE_IDS');
    final api = apiFor();
    for (final id in imageIds.split(',').where((s) => s.isNotEmpty)) {
      final fr = await api.getContentAuthed(server, id);
      expect(fr.data, isNotNull, reason: 'нет байт для $id');
      expect(fr.data.length, greaterThan(0), reason: 'пустое тело $id');
      // Реальный декод движком Flutter — то, что делает mxc_image при рендере.
      final codec = await ui.instantiateImageCodec(fr.data);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(0));
      expect(frame.image.height, greaterThan(0));
      // ignore: avoid_print
      print('  ✅ decode $id: ${fr.data.length}B '
          '${frame.image.width}x${frame.image.height} (${fr.contentType})');
    }
  });

  testWidgets('ПРОД MMR: клиентский upload→download durable round-trip',
      (tester) async {
    final api = apiFor();
    final payload = Uint8List.fromList(
        List<int>.generate(120000, (i) => (i * 2654435761) & 0xff));
    final uri = await api.uploadContent(payload,
        filename: 'client-durable-test.bin',
        contentType: 'application/octet-stream');
    expect(uri.scheme, 'mxc');
    final id = uri.pathSegments.last;
    final back = await api.getContentAuthed(uri.host, id);
    expect(back.data, isNotNull);
    expect(back.data.length, payload.length,
        reason: 'длина после round-trip не совпала (durable?)');
    var same = true;
    for (var i = 0; i < payload.length; i++) {
      if (back.data[i] != payload[i]) {
        same = false;
        break;
      }
    }
    expect(same, true, reason: 'байты после round-trip отличаются (durable?)');
    // ignore: avoid_print
    print('  ✅ client upload→download durable: mxc=${uri.toString()} '
        '${payload.length}B, байты совпали');
  });
}
