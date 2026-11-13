// ledger:RL-telegram-widgets
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:liza/pages/chat/tg_widget/tg_widget_api.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_bubble.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_engine.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_model.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_runtime.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_storage.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_trust.dart';

const testKid = 'k1';
const testPublicKey = 'PUBKEY-k1';

/// Фейковая «подпись»: sha256(ключ|сообщение). Ровно как Ed25519, она
/// ломается при любой правке подписанных полей, и её нельзя подобрать, не
/// зная ключа — этого достаточно для логики доверия без нативной vodozemac.
String fakeSign(String publicKey, String message) =>
    sha256.convert(utf8.encode('$publicKey|$message')).toString();

class FakeVerifier implements TgWidgetSignatureVerifier {
  int calls = 0;

  @override
  bool verify({
    required String publicKey,
    required String message,
    required String signature,
  }) {
    calls++;
    return fakeSign(publicKey, message) == signature;
  }
}

Map<String, Object?> widgetBlockJson({
  String html = '<div id="w">hi</div>',
  String sender = '@shop_bot:example.invalid',
  String botId = '@shop_bot:example.invalid',
  String roomId = '!w:example.invalid',
  String widgetId = '101',
  int width = 0,
  int height = 0,
  bool isShared = false,
  bool allowQueries = true,
  bool protectContent = false,
  String? chatData = '{"n":0}',
  String? publicData,
  String kid = testKid,
  bool sign = true,
  bool? hasCaption,
}) {
  final raw = <String, Object?>{
    'v': 1,
    'widget_id': widgetId,
    'bot_id': botId,
    'sender': sender,
    'room_id': roomId,
    'html': html,
    'width': width,
    'height': height,
    'is_shared': isShared,
    'allow_queries': allowQueries,
    'protect_content': protectContent,
    'chat_data': chatData,
    'public_data': publicData,
    'kid': kid,
    'sig': 'unsigned',
    'has_caption': ?hasCaption,
  };
  if (sign) {
    final block = TgWidgetBlock.tryParse(raw)!;
    raw['sig'] = fakeSign(testPublicKey, block.signedPayload());
  }
  return raw;
}

Map<String, Object?> widgetContent({
  String body = 'Счётчик',
  Map<String, Object?>? block,
}) => {
  'msgtype': 'm.text',
  'body': body,
  TgWidgetBlock.contentKey: block ?? widgetBlockJson(),
};

/// Фейковый liza-bot-api: ключи, проверенные боты, scopes, общие виджеты.
class FakeWidgetServer {
  final Set<String> verifiedBots;
  Set<String> scopes;
  final List<http.Request> requests = [];
  final Map<String, String?> sharedData = {};
  int sharedCacheTime = 30;
  FutureOr<Map<String, Object?>> Function(Map<String, Object?> body)? onQuery;

  /// Ответ `/liza/v1/widget-viewer`; `null` в поле — сервер не знает viewer,
  /// [viewerStatus] ≠ 200 — ошибка.
  Map<String, Object?>? viewer = {
    'id': 4242,
    'first_name': 'Алиса',
    'username': 'alice',
  };
  int viewerStatus = 200;
  int keysStatus = 200;

  FakeWidgetServer({
    this.verifiedBots = const {},
    this.scopes = const {'private'},
  });

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (path == '/liza/v1/widget-keys') {
      if (keysStatus != 200) return http.Response('err', keysStatus);
      return http.Response(
        jsonEncode({
          'keys': [
            {'kid': testKid, 'alg': 'ed25519', 'public_key': testPublicKey},
          ],
        }),
        200,
      );
    }
    if (path == '/liza/v1/widget-bot') {
      final mxid = request.url.queryParameters['mxid'];
      return http.Response(
        jsonEncode({
          'verified': verifiedBots.contains(mxid),
          'cache_time': 300,
        }),
        200,
      );
    }
    if (path == '/liza/v1/capabilities') {
      return http.Response(
        jsonEncode({
          'widgets': {'scopes': scopes.toList(), 'profile': 1},
        }),
        200,
      );
    }
    if (path.startsWith('/liza/v1/widgets/')) {
      final id = Uri.decodeComponent(path.split('/').last);
      if (!sharedData.containsKey(id)) return http.Response('{}', 404);
      final data = sharedData[id];
      final etag = '"${data.hashCode}"';
      if (request.headers['If-None-Match'] == etag) {
        return http.Response(
          '',
          304,
          headers: {'cache-control': 'max-age=$sharedCacheTime'},
        );
      }
      return http.Response(
        jsonEncode({
          'widget_id': id,
          'public_data': data,
          'cache_time': sharedCacheTime,
        }),
        200,
        headers: {'etag': etag, 'cache-control': 'max-age=$sharedCacheTime'},
      );
    }
    if (path == '/liza/v1/widget-viewer') {
      if (viewerStatus != 200) return http.Response('err', viewerStatus);
      // Без charset: клиент обязан декодировать UTF-8 сам (кириллица в имени).
      return http.Response.bytes(
        utf8.encode(jsonEncode({'viewer': viewer})),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path == '/liza/v1/widget-query') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final answer =
          await (onQuery?.call(body) ?? {'ok': true, 'result': 'ok'});
      return http.Response(jsonEncode(answer), 200);
    }
    return http.Response('not found', 404);
  });

  TgWidgetApi api(String base) => TgWidgetApi(base, httpClient: client);

  int count(String path) => requests.where((r) => r.url.path == path).length;
}

/// Фейковый движок: вместо WebView — пустой бокс, сообщения хоста пишутся в
/// [sent], сообщения «шима» подаются через [emit].
class FakeEngineHandle implements TgWidgetEngineHandle {
  final TgWidgetEngineConfig config;
  final List<Map<String, Object?>> sent = [];
  bool disposed = false;

  FakeEngineHandle(this.config);

  String get secret =>
      RegExp(r'"secret":"([0-9a-f]+)"').firstMatch(config.document)!.group(1)!;

  Map<String, Object?> get shimConfig {
    final m = RegExp(r'var CFG = (\{.*?\});\n').firstMatch(config.document)!;
    return jsonDecode(m.group(1)!) as Map<String, Object?>;
  }

  void emit(Map<String, Object?> msg) =>
      config.onMessage(jsonEncode({...msg, 's': secret}));

  /// Касание, которое видит хост: down → up на месте за 50 мс.
  void hostTap() => hostTapTo(config.onPointer);

  @override
  Future<void> send(String json) async {
    sent.add(jsonDecode(json) as Map<String, Object?>);
  }

  @override
  Future<Uint8List?> snapshot() async => Uint8List.fromList(onePixelPng);
}

class FakeEngines {
  static final List<FakeEngineHandle> live = [];
  static final List<FakeEngineHandle> created = [];

  static void install() {
    live.clear();
    created.clear();
    TgWidgetEngines.debugBuilder = (config) => _FakeEngine(config: config);
  }

  static void uninstall() {
    TgWidgetEngines.debugBuilder = null;
    TgWidgetEngines.debugSupported = null;
  }
}

class _FakeEngine extends StatefulWidget {
  final TgWidgetEngineConfig config;

  const _FakeEngine({required this.config});

  @override
  State<_FakeEngine> createState() => _FakeEngineState();
}

class _FakeEngineState extends State<_FakeEngine> {
  late final FakeEngineHandle handle = FakeEngineHandle(widget.config);

  @override
  void initState() {
    super.initState();
    FakeEngines.live.add(handle);
    FakeEngines.created.add(handle);
    widget.config.onCreated(handle);
  }

  @override
  void dispose() {
    handle.disposed = true;
    FakeEngines.live.remove(handle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('fake-tg-engine'));
}

int _pointerSeq = 100;

/// Тап для хостового гейта: down/up в одной точке.
void hostTapTo(
  ValueChanged<PointerEvent> onPointer, {
  Offset at = const Offset(10, 10),
}) {
  final p = _pointerSeq++;
  onPointer(PointerDownEvent(pointer: p, position: at));
  onPointer(PointerUpEvent(pointer: p, position: at));
}

/// Вертикальный свайп по виджету: down → move за пределы kTouchSlop → up.
void hostSwipeTo(ValueChanged<PointerEvent> onPointer) {
  final p = _pointerSeq++;
  onPointer(PointerDownEvent(pointer: p, position: const Offset(10, 100)));
  onPointer(
    PointerMoveEvent(
      pointer: p,
      position: const Offset(10, 60),
      delta: const Offset(0, -40),
    ),
  );
  onPointer(PointerUpEvent(pointer: p, position: const Offset(10, 60)));
}

/// Глобальные швы виджетов в исходное состояние.
void resetTgWidgetGlobals(FakeWidgetServer server, {int capacity = 2}) {
  TgWidgetApi.debugReset();
  TgWidgetApi.debugFactory = server.api;
  TgWidgetBubble.verifier = FakeVerifier();
  TgWidgetBubble.debugReset();
  TgWidgetLiveBudget.debugInstance = TgWidgetLiveBudget(capacity: capacity);
  TgWidgetPosters.debugClear();
  TgWidgetStorage.debugClear();
  TgWidgetOpenIdCache.debugOverride = () async => TgWidgetOpenId(
    accessToken: 'oid-token',
    matrixServerName: 'example.invalid',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );
  TgSharedWidgetPoller.instance.debugReset();
  FakeEngines.install();
}

void tearDownTgWidgetGlobals() {
  TgWidgetApi.debugFactory = null;
  TgWidgetApi.debugReset();
  TgWidgetBubble.verifier = const VodozemacTgWidgetVerifier();
  TgWidgetLiveBudget.debugInstance = null;
  TgWidgetOpenIdCache.debugOverride = null;
  TgSharedWidgetPoller.instance.debugReset();
  FakeEngines.uninstall();
  TgWidgetEngines.debugLiveOnlyForVerified = null;
}

const List<int> onePixelPng = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
