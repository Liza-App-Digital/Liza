import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

@JS('URL.revokeObjectURL')
external void _revokeObjectURL(String url);

/// Освобождает `blob:` URL записи: вкладка живёт сутками, и без этого каждое
/// голосовое держало бы свои байты в памяти до перезагрузки.
void revokeObjectUrl(String url) {
  if (url.startsWith('blob:')) _revokeObjectURL(url);
}

/// Скачивание браузером через `<a download>`. В отличие от file_picker на Web
/// не требует расширения в имени и принимает пустой файл (заявка №51). URL
/// отзываем с задержкой: мгновенный revoke в Safari и Firefox обрывает загрузку.
void downloadBytes(String fileName, Uint8List bytes, String mimeType) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..click();
  Timer(const Duration(seconds: 1), () => revokeObjectUrl(url));
}
