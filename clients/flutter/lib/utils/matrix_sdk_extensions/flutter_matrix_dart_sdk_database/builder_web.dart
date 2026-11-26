import 'package:flutter/services.dart';

import 'package:matrix/matrix.dart';
import 'package:universal_html/html.dart' as html;

/// [allowQuarantine] нужен для единой сигнатуры с native: в браузере файлов БД
/// нет, хранилище — IndexedDB.
Future<DatabaseApi> flutterMatrixSdkDatabaseBuilder(
  String clientName, {
  bool allowQuarantine = true,
}) async {
  try {
    html.window.navigator.storage?.persist();
    return await MatrixSdkDatabase.init(clientName);
  } on PlatformException catch (e, s) {
    Logs().wtf(
      'Unable to construct database (temporary platform error)!',
      e,
      s,
    );
    rethrow;
  } catch (e, s) {
    Logs().wtf('Unable to construct database!', e, s);
    rethrow;
  }
}
