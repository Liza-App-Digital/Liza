import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// Состояние принадлежит инстансу приложения, а не пересоздаваемому host.
class MiniAppInteractiveState {
  bool active = true;
  bool authenticated = false;
  String? documentId;
  String? queryId;
  int queryExpiresAt = 0;
  Future<String?>? creatingQuery;
  Future<void> Function()? cancelQuery;
  bool presenting = false;
  bool visible = true;
  int visibilityEpoch = 0;
  int? nativeVisibilityEpoch;
  int nativeSnapshotSequence = -1;
  int? nativeFocusEpoch;
  int? nativeMainFocusEpoch;
  bool mainFocusTransferred = false;
  int? presentationVisibilityEpoch;

  void beginPresentation() {
    presenting = true;
    mainFocusTransferred = false;
    presentationVisibilityEpoch = visibilityEpoch;
  }

  final requestEpochs = <String, int>{};

  void setVisible(bool value) {
    if (visible && !value) visibilityEpoch++;
    if (!value) mainFocusTransferred = false;
    visible = value;
  }

  final cancelledRequests = <String>{};

  void invalidate() {
    active = false;
    authenticated = false;
    documentId = null;
    final cancel = cancelQuery;
    if (cancel != null) unawaited(cancel());
  }
}

String miniAppCapability() {
  final random = Random.secure();
  return List.generate(
    24,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Nonce живёт только в closure верхнего доверенного документа. Нативный
/// callHandler, доступный iframe в старом плагине, сам по себе прав не даёт.
String miniAppBridgeScript(String? allowedOrigin) =>
    '''
(function() {
  if (window.top !== window) return;
  var allowed = ${jsonEncode(allowedOrigin)};
  var nonce = null;
  var queue = [];
  var handler = null;
  window.__lizaBridge = {
    postEvent: function(type, data) {
      var sensitive = /^(web_app_request_contact|web_app_share_message|web_app_choose_prepared_keyboard_button|web_app_query_result|web_app_cancel_interactive)\$/.test(type);
      if (sensitive && (!allowed || window.location.origin !== allowed)) return;
      var item = {eventType:type,eventData:data || {},sensitive:sensitive};
      if (handler) handler(item); else queue.push(item);
    },
    _activate: function(documentNonce) {
      nonce = documentNonce;
      handler = function(item) {
        if (item.sensitive && !nonce) { queue.push(item); return; }
        var msg = {eventType:item.eventType,eventData:item.eventData};
        if (item.sensitive) msg.capability = nonce;
        window.flutter_inappwebview.callHandler('LizaWebAppHandler', JSON.stringify(msg));
      };
      var waiting = queue;
      queue=[];
      for (var i=0;i<waiting.length;i++) handler(waiting[i]);
    }
  };
})();
''';

bool miniAppSensitiveOriginAllowed({
  required String? allowedOrigin,
  required String? currentUrl,
  required String? loadedUrl,
}) {
  if (allowedOrigin == null || currentUrl == null || loadedUrl == null) {
    return false;
  }
  final current = Uri.tryParse(currentUrl);
  final loaded = Uri.tryParse(loadedUrl);
  return current?.scheme == 'https' &&
      loaded?.scheme == 'https' &&
      current?.origin == allowedOrigin &&
      loaded?.origin == allowedOrigin;
}

/// Прямой запуск (включая сторонний app) доверяет только origin его URL.
/// При фактической загрузке shell capability доступна только shell-документу.
/// Право приложения на данные отдельно проверяется актуальным AppRegistry.
String? miniAppInteractiveOrigin({required String appUrl, String? shellUrl}) {
  final uri = Uri.tryParse(shellUrl ?? appUrl);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri.origin;
}
