import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liza/widgets/mxc_image.dart';

/// ledger:RL-mxc-avatar-bad-bytes
///
/// Второй корень «человечка вместо фото» (Надежда/Рома 09.11): валидные байты
/// аватарки вытеснялись из процессного LRU (50 записей, общий на всё
/// приложение) длинным списком чатов, а keep-alive лента сториз перестраивалась
/// на sync — `build` видел null и рисовал placeholder навсегда (перезагрузка
/// только из initState). Фикс — своя ссылка State на показанные байты.
///
/// Байты засеваются в LRU ДО монтирования: тогда `_tryLoad` выходит раньше
/// `_load`, и живой Matrix Client тесту не нужен (с ним widget-тест виснет).
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

// Валидный PNG-magic, но усечён — проходит looksLikeImageMagic, не декодируется.
final _truncatedPng = Uint8List.fromList(_png.sublist(0, 24));

final _uri = Uri.parse('mxc://liza.test/avatar');

Widget _host(String cacheKey, {Key? key}) => MaterialApp(
  home: Center(
    child: MxcImage(
      key: key,
      uri: _uri,
      width: 65,
      height: 65,
      cacheKey: cacheKey,
      placeholder: (_) => const Icon(Icons.person_2),
      failedBuilder: (_) => const Text('A'),
    ),
  ),
);

Uint8List? _shownBytes(WidgetTester tester) {
  final images = tester.widgetList<Image>(find.byType(Image));
  if (images.isEmpty) return null;
  final provider = images.first.image;
  if (provider is MemoryImage) return provider.bytes;
  if (provider is ResizeImage && provider.imageProvider is MemoryImage) {
    return (provider.imageProvider as MemoryImage).bytes;
  }
  return null;
}

/// Список чатов наполняет LRU чужими аватарками (свой ключ уже вытеснен).
void _flood() {
  for (var i = 0; i < 50; i++) {
    MxcImage.seedImageCache('other_$i', _png);
  }
}

void main() {
  setUp(MxcImage.clearImageCache);
  tearDown(MxcImage.clearImageCache);

  group('AC:RL-mxc-avatar-bad-bytes/4 вытеснение из LRU + rebuild', () {
    testWidgets('аватарка остаётся фото, не человечком', (tester) async {
      final bytes = Uint8List.fromList(_png);
      MxcImage.seedImageCache('k_65', bytes);
      await tester.pumpWidget(_host('k_65'));
      await tester.pump();
      expect(identical(_shownBytes(tester), bytes), isTrue);

      MxcImage.evictImageCache('k_65');
      _flood();
      // Rebuild ленты на sync: тот же State, didUpdateWidget без смены identity.
      await tester.pumpWidget(_host('k_65'));
      await tester.pump(const Duration(seconds: 1));

      expect(find.byIcon(Icons.person_2), findsNothing);
      expect(identical(_shownBytes(tester), bytes), isTrue);
    });
  });

  group('AC:RL-mxc-avatar-bad-bytes/5 восстановление не мутирует LRU', () {
    testWidgets('после rebuild ключи LRU те же, запись не возвращена', (
      tester,
    ) async {
      MxcImage.seedImageCache('k_65', Uint8List.fromList(_png));
      await tester.pumpWidget(_host('k_65'));
      await tester.pump();

      MxcImage.evictImageCache('k_65');
      _flood();
      final before = MxcImage.imageCacheKeys();
      await tester.pumpWidget(_host('k_65'));
      await tester.pump();

      expect(MxcImage.imageCacheKeys(), before);
      expect(MxcImage.imageCacheKeys(), isNot(contains('k_65')));
    });
  });

  group('AC:RL-mxc-avatar-bad-bytes/6 смена cacheKey сбрасывает копию', () {
    testWidgets('под новым ключом — байты нового ключа, не старые', (
      tester,
    ) async {
      final a = Uint8List.fromList(_png);
      final b = Uint8List.fromList(_png);
      MxcImage.seedImageCache('a_65', a);
      MxcImage.seedImageCache('b_65', b);
      await tester.pumpWidget(_host('a_65'));
      await tester.pump();
      expect(identical(_shownBytes(tester), a), isTrue);

      MxcImage.evictImageCache('a_65');
      await tester.pumpWidget(_host('b_65'));
      await tester.pump();

      final shown = _shownBytes(tester);
      expect(identical(shown, b), isTrue);
      expect(identical(shown, a), isFalse);
    });
  });

  group('AC:RL-mxc-avatar-bad-bytes/7 байты от соседнего виджета', () {
    testWidgets('виджет без своего _load переживает вытеснение', (
      tester,
    ) async {
      // Байты положил «сосед» (другой экран) — этот виджет их только прочитал.
      final bytes = Uint8List.fromList(_png);
      MxcImage.seedImageCache('k_65', bytes);
      await tester.pumpWidget(_host('k_65'));
      await tester.pump();

      MxcImage.clearImageCache();
      await tester.pumpWidget(_host('k_65'));
      await tester.pump();

      expect(find.byIcon(Icons.person_2), findsNothing);
      expect(identical(_shownBytes(tester), bytes), isTrue);
    });
  });

  group('AC:RL-mxc-avatar-bad-bytes/8 не декодируется → буква, без возврата', () {
    testWidgets('битые байты не держатся копией после rebuild', (tester) async {
      MxcImage.seedImageCache('k_65', _truncatedPng);
      await tester.pumpWidget(_host('k_65'));
      // Декодер работает вне fake-async: даём ему реальное время на ошибку.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      // Rebuild между errorBuilder и postframe-сбросом — дыра из вердикта судьи.
      await tester.pumpWidget(_host('k_65'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(MxcImage.imageCacheKeys(), isNot(contains('k_65')));
      expect(find.byType(Image), findsNothing);
      expect(find.text('A'), findsOneWidget);

      // Ещё один rebuild ленты — буква остаётся, битые байты не вернулись.
      await tester.pumpWidget(_host('k_65'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(Image), findsNothing);
      expect(find.text('A'), findsOneWidget);
    });
  });
}
