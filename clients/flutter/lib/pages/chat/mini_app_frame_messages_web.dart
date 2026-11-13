import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS('JSON.stringify')
external JSString _stringify(JSAny? value);

/// На Web мини-апп живёт в iframe с чужого домена: `__lizaBridge` туда не
/// подложить, и SDK страницы шлёт события `window.parent.postMessage(
/// '{"eventType":…,"eventData":…}')`. Принимаем только сообщения с origin
/// открытого мини-аппа. Возвращает функцию отписки.
void Function() listenMiniAppFrameMessages(
  String origin,
  void Function(String rawMessage) onMessage,
) {
  void handle(web.MessageEvent event) {
    if (event.origin != origin) return;
    final data = event.data;
    if (data.isA<JSString>()) {
      onMessage((data as JSString).toDart);
    } else if (data != null && data.isA<JSObject>()) {
      onMessage(_stringify(data).toDart);
    }
  }

  final listener = handle.toJS;
  web.window.addEventListener('message', listener);
  return () => web.window.removeEventListener('message', listener);
}
