import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:file_picker/file_picker.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_file_extension.dart';

class _ThrowingFilePicker extends FilePicker {
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async =>
      throw ArgumentError('The file name should include a valid file extension.');
}

void main() {
  // ledger:RL-web-file-save-any-name
  testWidgets(
    'сбой сохранения показывает SnackBar, а не уходит молча в zone',
    (tester) async {
      // AC:RL-web-file-save-any-name/3
      FilePicker.platform = _ThrowingFilePicker();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => MatrixFile(
                  bytes: Uint8List.fromList([1, 2, 3]),
                  name: 'report.txt',
                  mimeType: 'text/plain',
                ).save(context),
                child: const Text('save'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Не удалось сохранить файл'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
