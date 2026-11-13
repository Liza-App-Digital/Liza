import 'package:flutter/widgets.dart';

import 'package:liza/pages/chat/events/fluid_page_web_frame_stub.dart'
    if (dart.library.js_interop) 'package:liza/pages/chat/events/fluid_page_web_frame_web.dart';

/// Страница Лизы на Web: изолированный `<iframe sandbox>` с готовым документом
/// (CSP уже внутри, см. `fluidPageDocument`). Вне Web — пусто: там страницу
/// открывает WebView мини-аппа.
Widget fluidPageWebFrame(String document) => buildFluidPageWebFrame(document);

/// Ссылки страницы — в новой вкладке: внутри песочницы переход увёл бы сам
/// iframe на чужой сайт (а тот обычно не даёт встраивать себя). Первый атрибут
/// в теге главнее, поэтому наш `target` перекрывает модельный.
String fluidPageLinksInNewTab(String html) => html.replaceAllMapped(
  RegExp(r'<a(\s)', caseSensitive: false),
  (m) => '<a target="_blank" rel="noopener noreferrer"${m[1]}',
);
