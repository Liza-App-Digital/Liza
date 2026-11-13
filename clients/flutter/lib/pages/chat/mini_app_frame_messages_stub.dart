/// Вне Web мост мини-аппа идёт через addJavaScriptHandler, слушать нечего.
void Function() listenMiniAppFrameMessages(
  String origin,
  void Function(String rawMessage) onMessage,
) =>
    () {};
