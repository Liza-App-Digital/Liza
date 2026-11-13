import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

import 'package:web/web.dart' as web;

Widget buildFluidPageWebFrame(String document) =>
    _FluidPageWebFrame(document: document);

int _viewSeq = 0;

class _Slot {
  web.HTMLIFrameElement? iframe;
  _Slot(this.iframe);
}

/// `sandbox` без `allow-scripts` и без `allow-same-origin`: непрозрачный origin,
/// JS не исполняется (его и CSP запрещает), к хранилищу приложения доступа нет.
/// `allow-popups*` — только чтобы ссылки «купить» открывались в новой вкладке.
class _FluidPageWebFrame extends StatefulWidget {
  final String document;
  const _FluidPageWebFrame({required this.document});

  @override
  State<_FluidPageWebFrame> createState() => _FluidPageWebFrameState();
}

class _FluidPageWebFrameState extends State<_FluidPageWebFrame> {
  late final String _viewType = 'liza-fluid-page-${_viewSeq++}';
  late final _Slot _slot;

  @override
  void initState() {
    super.initState();
    final iframe = web.document.createElement('iframe') as web.HTMLIFrameElement
      ..setAttribute('sandbox', 'allow-popups allow-popups-to-escape-sandbox')
      ..setAttribute('referrerpolicy', 'no-referrer')
      ..setAttribute('allow', '')
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.background = 'white';
    iframe.srcdoc = widget.document.toJS;
    _slot = _Slot(iframe);
    final slot = _slot;
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int _) => slot.iframe ?? web.document.createElement('div'),
    );
  }

  @override
  void dispose() {
    _slot.iframe?.srcdoc = ''.toJS;
    _slot.iframe?.remove();
    _slot.iframe = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
