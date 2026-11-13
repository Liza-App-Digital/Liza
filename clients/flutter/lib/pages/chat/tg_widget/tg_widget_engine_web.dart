import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

import 'package:web/web.dart' as web;

import 'package:liza/pages/chat/tg_widget/tg_widget_engine.dart';

Widget buildWebTgWidgetEngine(TgWidgetEngineConfig config) =>
    _WebTgWidgetEngine(config: config);

int _viewSeq = 0;

/// Реестр фабрик платформенных видов вечный: фабрика держит только этот
/// контейнер, а iframe и State из него убираются в dispose.
class _IframeSlot {
  web.HTMLIFrameElement? iframe;
  _IframeSlot(this.iframe);
}

/// Web: `<iframe sandbox="allow-scripts" srcdoc>` — непрозрачный origin, без
/// доступа к cookies/хранилищу приложения и без навигации наверх. Мост —
/// `postMessage` только от ИСХОДНОГО документа iframe: после второй загрузки
/// (самонавигация) сообщения не принимаются вовсе.
class _WebTgWidgetEngine extends StatefulWidget {
  final TgWidgetEngineConfig config;

  const _WebTgWidgetEngine({required this.config});

  @override
  State<_WebTgWidgetEngine> createState() => _WebTgWidgetEngineState();
}

class _WebTgWidgetEngineState extends State<_WebTgWidgetEngine>
    implements TgWidgetEngineHandle {
  late final String _viewType = 'liza-tg-widget-${_viewSeq++}';
  late final web.HTMLIFrameElement _iframe;
  late final _IframeSlot _slot;
  JSFunction? _listener;
  JSFunction? _loadListener;
  JSFunction? _blurListener;
  Timer? _refocus;
  int _loads = 0;

  @override
  void initState() {
    super.initState();
    _iframe = web.document.createElement('iframe') as web.HTMLIFrameElement
      ..setAttribute('sandbox', 'allow-scripts')
      ..setAttribute('referrerpolicy', 'no-referrer')
      ..setAttribute('allow', '')
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.background = 'transparent';
    _iframe.srcdoc = widget.config.document.toJS;
    _slot = _IframeSlot(_iframe);

    void onMessage(web.MessageEvent event) {
      if (!mounted || _loads > 1) return;
      // Только JS-сравнение `===`: Dart `!=` в dart2js зовёт перехватчик, тот
      // читает служебное свойство у cross-origin окна iframe → SecurityError,
      // и ВСЕ сообщения шима терялись (стартовый сторож гасил виджет за 3 с).
      final source = event.source;
      if (source == null ||
          !source.strictEquals(_iframe.contentWindow).toDart) {
        return;
      }
      final data = event.data;
      if (data != null && data.isA<JSString>()) {
        widget.config.onMessage((data as JSString).toDart);
      }
    }

    void onLoad(web.Event _) {
      if (!mounted) return;
      _loads++;
      if (_loads > 1) widget.config.onUnexpectedNavigation();
    }

    // Хостовый сигнал активации: клик в iframe уводит фокус окна в него
    // (blur + activeElement === iframe). Потом фокус возвращаем, чтобы
    // следующий клик снова дал blur.
    void onBlur(web.Event _) {
      if (!mounted) return;
      if (web.document.activeElement != _iframe) return;
      widget.config.onActivation();
      _refocus?.cancel();
      _refocus = Timer(const Duration(milliseconds: 300), () {
        if (web.document.activeElement == _iframe) {
          _iframe.blur();
          web.window.focus();
        }
      });
    }

    _listener = onMessage.toJS;
    _loadListener = onLoad.toJS;
    _blurListener = onBlur.toJS;
    web.window.addEventListener('message', _listener);
    web.window.addEventListener('blur', _blurListener);
    _iframe.addEventListener('load', _loadListener);
    final slot = _slot;
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int _) => slot.iframe ?? web.document.createElement('div'),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.config.onCreated(this);
    });
  }

  @override
  void dispose() {
    _refocus?.cancel();
    final listener = _listener;
    if (listener != null) web.window.removeEventListener('message', listener);
    final blur = _blurListener;
    if (blur != null) web.window.removeEventListener('blur', blur);
    final load = _loadListener;
    if (load != null) _iframe.removeEventListener('load', load);
    _iframe.srcdoc = ''.toJS;
    _iframe.remove();
    _slot.iframe = null;
    super.dispose();
  }

  @override
  Future<void> send(String json) async {
    if (!mounted || _loads > 1) return;
    _iframe.contentWindow?.postMessage(json.toJS, '*'.toJS);
  }

  @override
  Future<Uint8List?> snapshot() async => null;

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
