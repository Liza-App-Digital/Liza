import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// CSP обёртки. Мета идёт ПЕРВОЙ в `<head>`: несколько политик только
/// сужают друг друга, так что CSP из HTML виджета её не ослабит. `form-action`
/// и `base-uri` не наследуются от `default-src` — пишем явно.
const String tgWidgetCsp =
    "default-src 'none'; script-src 'unsafe-inline'; "
    "style-src 'unsafe-inline'; img-src data: blob:; font-src data:; "
    "media-src 'none'; connect-src 'none'; frame-src 'none'; "
    "child-src 'none'; worker-src 'none'; object-src 'none'; "
    "manifest-src 'none'; form-action 'none'; base-uri 'none'";

/// Элементы вне профиля 1 (формы и ввод, фреймы, медиа, диалоги) и всё, что
/// умеет ходить в сеть мимо CSP (`link` — prefetch/dns-prefetch/preconnect).
const Set<String> tgWidgetBannedTags = {
  'form',
  'input',
  'textarea',
  'select',
  'option',
  'optgroup',
  'datalist',
  'output',
  'fieldset',
  'legend',
  'iframe',
  'frame',
  'frameset',
  'object',
  'embed',
  'applet',
  'portal',
  'fencedframe',
  'audio',
  'video',
  'source',
  'track',
  'dialog',
  'progress',
  'meter',
  'link',
  'base',
  'meta',
};

/// Предварительная чистка HTML виджета до загрузки: то же, что делает шим, но
/// раньше парсера браузера — `<link rel=dns-prefetch>` или `meta refresh` из
/// статического HTML иначе успели бы сработать до `MutationObserver`.
({
  String head,
  String body,
  Map<String, String> htmlAttrs,
  Map<String, String> bodyAttrs,
})
sanitizeTgWidgetHtml(String html) {
  final doc = html_parser.parse(html);
  void clean(dom.Element root) {
    for (final el in root.querySelectorAll('*').toList()) {
      final tag = el.localName?.toLowerCase() ?? '';
      if (tgWidgetBannedTags.contains(tag) ||
          (tag == 'script' && el.attributes.containsKey('src')) ||
          (tag == 'template' &&
              (el.attributes.containsKey('shadowrootmode') ||
                  el.attributes.containsKey('shadowroot')))) {
        el.remove();
        continue;
      }
      el.attributes.removeWhere((k, _) {
        final name = k.toString().toLowerCase();
        return name == 'contenteditable' ||
            name == 'formaction' ||
            name == 'ping' ||
            name == 'srcset' ||
            name == 'autofocus';
      });
      if (tag == 'img') {
        final src = el.attributes['src'];
        if (src != null && src.trim().toLowerCase().startsWith('mxc://')) {
          el.attributes.remove('src');
          el.attributes['data-tgw-mxc'] = src.trim();
        }
      }
    }
  }

  final head = doc.head;
  final body = doc.body;
  if (head != null) clean(head);
  if (body != null) clean(body);
  Map<String, String> safeAttrs(dom.Element? el) => {
    for (final e in (el?.attributes ?? const {}).entries)
      if (const {
        'class',
        'style',
        'dir',
        'lang',
      }.contains(e.key.toString().toLowerCase()))
        e.key.toString(): e.value,
  };
  final headContent = StringBuffer();
  for (final el in head?.children ?? const <dom.Element>[]) {
    final tag = el.localName?.toLowerCase();
    if (tag == 'style' || tag == 'script') headContent.write(el.outerHtml);
  }
  return (
    head: headContent.toString(),
    body: body?.innerHtml ?? '',
    htmlAttrs: safeAttrs(doc.documentElement),
    bodyAttrs: safeAttrs(body),
  );
}

String _escapeAttr(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;');

String _attrs(Map<String, String> a) =>
    a.entries.map((e) => ' ${e.key}="${_escapeAttr(e.value)}"').join();

/// JSON внутри `<script>`: `<` → `<`, иначе `</script>` в `chat_data`
/// закрыл бы тег шима и выполнил бы данные бота как разметку.
String tgWidgetScriptJson(Object? value) => jsonEncode(value)
    .replaceAll('<', r'\u003c')
    .replaceAll('\u2028', r'\u2028')
    .replaceAll('\u2029', r'\u2029');

/// Документ-обёртка: CSP → базовые стили → шим → HTML виджета.
String buildTgWidgetDocument({
  required String widgetHtml,
  required Map<String, Object?> config,
  String colorScheme = 'light',
}) {
  final clean = sanitizeTgWidgetHtml(widgetHtml);
  final shim = tgWidgetShimSource.replaceFirst(
    '__TGW_CFG__',
    tgWidgetScriptJson(config),
  );
  return '<!doctype html><html${_attrs(clean.htmlAttrs)}><head>'
      '<meta http-equiv="Content-Security-Policy" content="$tgWidgetCsp">'
      '<meta charset="utf-8">'
      '<meta http-equiv="x-dns-prefetch-control" content="off">'
      '<meta name="referrer" content="no-referrer">'
      // prefers-color-scheme внутри виджета = тема чата, а не системы.
      '<meta name="color-scheme" content="${colorScheme == 'dark' ? 'dark' : 'light'}">'
      '<meta name="viewport" content="width=device-width,initial-scale=1,'
      'maximum-scale=1,user-scalable=no">'
      '<style>html{height:auto;overflow:hidden;background:transparent;'
      '-webkit-text-size-adjust:100%;-webkit-touch-callout:none;'
      '-webkit-user-select:none;user-select:none}'
      'body{margin:0;display:flow-root;overflow:hidden;'
      'background:transparent;color:var(--tg-theme-text-color);'
      'font-family:-apple-system,system-ui,Roboto,"Segoe UI",sans-serif;'
      'font-size:var(--tg-text-font-size);'
      'line-height:var(--tg-text-line-height)}</style>'
      '<script>$shim</script>'
      '${clean.head}'
      '</head><body${_attrs(clean.bodyAttrs)}>${clean.body}</body></html>';
}

/// Шим профиля 1: `window.TelegramWidget` (Telegram, один в один, кроме
/// `wallet === null`), `window.LizaWidget`, блок сети, чистка DOM, счётчик
/// узлов, heartbeat, мост к хосту. Выполняется ДО любого кода виджета.
///
/// Мост: виджет → хост — JSON `{s: секрет, t: тип, ...}` через
/// `flutter_inappwebview.callHandler('tgw', …)` (нативно) или
/// `parent.postMessage` (Web). Хост → виджет — `window.__tgwIn(json)` или
/// `postMessage` с тем же секретом. Секрет отсекает сообщения, которые код
/// виджета мог бы подделать в обход шима (но гейт тапа хост проверяет сам).
const String tgWidgetShimSource = r'''
(function () {
  'use strict';
  var CFG = __TGW_CFG__;
  var W = window, D = document;
  var dp = Object.defineProperty;
  var SECRET = CFG.secret;
  var lock = function (obj, name, value) {
    try { dp(obj, name, { value: value, writable: false, configurable: false, enumerable: false }); } catch (e) {}
  };
  var lockGetter = function (obj, name, get, set) {
    try { dp(obj, name, { get: get, set: set || function () {}, configurable: false, enumerable: true }); } catch (e) {}
  };

  // ---------- транспорт ----------
  var PARENT = W.parent;
  var webMode = CFG.transport === 'web';
  var CH = null;
  var outbox = [];
  function bindNative() {
    if (CH) return true;
    var fi = W.flutter_inappwebview;
    if (!fi || typeof fi.callHandler !== 'function') return false;
    CH = fi.callHandler.bind(fi);
    try { dp(fi, 'callHandler', { writable: false, configurable: false }); } catch (e) {}
    try { dp(W, 'flutter_inappwebview', { writable: false, configurable: false }); } catch (e) {}
    return true;
  }
  function post(msg) {
    msg.s = SECRET;
    var raw = JSON.stringify(msg);
    if (webMode) { PARENT.postMessage(raw, CFG.parentOrigin || '*'); return; }
    if (!bindNative()) { outbox.push(raw); return; }
    CH('tgw', raw);
  }
  if (!webMode) {
    bindNative();
    W.addEventListener('flutterInAppWebViewPlatformReady', function () {
      if (bindNative()) { var q = outbox; outbox = []; for (var i = 0; i < q.length; i++) CH('tgw', q[i]); }
    });
  }

  // ---------- ошибки ----------
  class NetworkDisabledError extends Error {
    constructor(message) { super(message || 'Network access is disabled in widgets'); this.name = 'NetworkDisabledError'; }
  }
  class WidgetRequestError extends Error {
    constructor(code, message) { super(message || code); this.name = 'WidgetRequestError'; this.code = code; }
  }
  lock(W, 'NetworkDisabledError', NetworkDisabledError);
  lock(W, 'WidgetRequestError', WidgetRequestError);
  function netBlocked() { throw new NetworkDisabledError(); }
  function BlockedCtor() { throw new NetworkDisabledError(); }

  // ---------- сеть ----------
  lock(W, 'fetch', function fetch() { netBlocked(); });
  ['XMLHttpRequest', 'WebSocket', 'EventSource', 'RTCPeerConnection', 'webkitRTCPeerConnection',
   'RTCDataChannel', 'RTCIceTransport', 'WebTransport', 'Worker', 'SharedWorker', 'BroadcastChannel']
    .forEach(function (n) { lock(W, n, BlockedCtor); });
  try { if (W.Navigator) lock(Navigator.prototype, 'sendBeacon', function sendBeacon() { netBlocked(); }); } catch (e) {}
  lock(navigator, 'sendBeacon', function sendBeacon() { netBlocked(); });
  // Геттеры — на ПРОТОТИПЕ Navigator: инстанс-свойство обходится через
  // Object.getOwnPropertyDescriptor(Navigator.prototype, …).
  ['serviceWorker', 'clipboard', 'share', 'geolocation', 'mediaDevices', 'storage', 'credentials',
   'bluetooth', 'usb', 'serial', 'hid', 'xr', 'locks', 'wakeLock']
    .forEach(function (n) {
      if (W.Navigator) lockGetter(Navigator.prototype, n, function () { return undefined; });
      lockGetter(navigator, n, function () { return undefined; });
    });
  lock(W, 'open', function open() { return null; });
  lock(W, 'alert', function alert() {});
  lock(W, 'print', function print() {});
  lock(W, 'confirm', function confirm() { return false; });
  lock(W, 'prompt', function prompt() { return null; });
  lockGetter(W, 'indexedDB', function () { return undefined; });
  lockGetter(W, 'caches', function () { return undefined; });
  lockGetter(W, 'Notification', function () { return undefined; });
  [Document.prototype, D].forEach(function (o) {
    lockGetter(o, 'cookie', function () { return ''; }, function () {});
    lockGetter(o, 'designMode', function () { return 'off'; }, function () {});
    ['open', 'write', 'writeln'].forEach(function (n) { lock(o, n, function () {}); });
  });

  // ---------- хранилище: своё на экземпляр, 4 КБ на область ----------
  function makeStorage(area, init) {
    var data = Object.create(null);
    if (init && typeof init === 'object') Object.keys(init).forEach(function (k) { data[k] = String(init[k]); });
    function size(d) {
      var n = 0; Object.keys(d).forEach(function (k) { n += new TextEncoder().encode(k).length + new TextEncoder().encode(d[k]).length; });
      return n;
    }
    function sync() { post({ t: 'storage', area: area, data: data }); }
    var st = {
      get length() { return Object.keys(data).length; },
      key: function (i) { var k = Object.keys(data); return i >= 0 && i < k.length ? k[i] : null; },
      getItem: function (k) { k = String(k); return k in data ? data[k] : null; },
      setItem: function (k, v) {
        k = String(k); v = String(v);
        var next = Object.assign(Object.create(null), data); next[k] = v;
        if (size(next) > CFG.quota) throw new DOMException('Storage quota exceeded', 'QuotaExceededError');
        data[k] = v; sync();
      },
      removeItem: function (k) { k = String(k); if (k in data) { delete data[k]; sync(); } },
      clear: function () { Object.keys(data).forEach(function (k) { delete data[k]; }); sync(); }
    };
    return Object.freeze(st);
  }
  var LS = makeStorage('local', CFG.storage && CFG.storage.local);
  var SS = makeStorage('session', CFG.storage && CFG.storage.session);
  lockGetter(W, 'localStorage', function () { return LS; });
  lockGetter(W, 'sessionStorage', function () { return SS; });

  // ---------- чистка DOM ----------
  var BANNED = {};
  CFG.banned.forEach(function (t) { BANNED[t] = true; });
  var origRemove = Element.prototype.remove;
  var origRemoveAttr = Element.prototype.removeAttribute;
  var origGetAttr = Element.prototype.getAttribute;
  function isBanned(el) {
    if (!el || el.nodeType !== 1) return false;
    var tag = (el.localName || '').toLowerCase();
    if (BANNED[tag]) return true;
    if (tag === 'script' && el.hasAttribute('src')) return true;
    // Декларативный shadow DOM: содержимое ушло бы мимо санитайзера.
    if (tag === 'template' && (el.hasAttribute('shadowrootmode') || el.hasAttribute('shadowroot'))) return true;
    return false;
  }
  function cleanAttrs(el) {
    ['contenteditable', 'formaction', 'ping', 'srcset', 'autofocus'].forEach(function (a) {
      if (el.hasAttribute && el.hasAttribute(a)) origRemoveAttr.call(el, a);
    });
  }
  // Возвращает false, если сам узел запрещён (его не вставляем).
  function clean(node, dropScripts) {
    if (!node) return true;
    if (node.nodeType === 1) {
      if (isBanned(node) || (dropScripts && node.localName === 'script')) return false;
      cleanAttrs(node);
    }
    if (node.querySelectorAll) {
      var all = node.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        if (isBanned(el) || (dropScripts && el.localName === 'script')) { origRemove.call(el); continue; }
        cleanAttrs(el);
      }
    }
    return true;
  }
  function frameGuard(proto) {
    if (!proto) return;
    ['contentWindow', 'contentDocument'].forEach(function (n) { lockGetter(proto, n, function () { return null; }); });
    lock(proto, 'getSVGDocument', function () { return null; });
  }
  frameGuard(W.HTMLIFrameElement && HTMLIFrameElement.prototype);
  frameGuard(W.HTMLFrameElement && HTMLFrameElement.prototype);
  frameGuard(W.HTMLObjectElement && HTMLObjectElement.prototype);
  frameGuard(W.HTMLEmbedElement && HTMLEmbedElement.prototype);
  if (W.Element && Element.prototype.attachShadow) lock(Element.prototype, 'attachShadow', function () { throw new DOMException('Not supported', 'NotSupportedError'); });

  // Вставка узлов: запрещённые элементы не попадают в документ синхронно —
  // `MutationObserver` срабатывает позже, а фрейм успел бы дать свежий `fetch`.
  function guardInsert(proto, name, nodeArgIndexes) {
    var orig = proto && proto[name];
    if (typeof orig !== 'function') return;
    lock(proto, name, function () {
      var args = Array.prototype.slice.call(arguments);
      for (var i = 0; i < args.length; i++) {
        if ((nodeArgIndexes === 'all' || nodeArgIndexes.indexOf(i) >= 0) && args[i] && typeof args[i] === 'object') {
          if (!clean(args[i], false)) {
            if (nodeArgIndexes === 'all') { args.splice(i, 1); i--; continue; }
            return args[i];
          }
        }
      }
      return orig.apply(this, args);
    });
  }
  guardInsert(Node.prototype, 'appendChild', [0]);
  guardInsert(Node.prototype, 'insertBefore', [0]);
  guardInsert(Node.prototype, 'replaceChild', [0]);
  ['append', 'prepend', 'before', 'after', 'replaceWith', 'replaceChildren'].forEach(function (n) {
    guardInsert(Element.prototype, n, 'all');
    guardInsert(DocumentFragment.prototype, n, 'all');
    guardInsert(Document.prototype, n, 'all');
  });
  guardInsert(Element.prototype, 'insertAdjacentElement', [1]);
  if (W.Range) {
    guardInsert(Range.prototype, 'insertNode', [0]);
    lock(Range.prototype, 'createContextualFragment', function (html) { return parseClean(html); });
  }

  var innerDesc = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
  var origCreate = Document.prototype.createElement;
  var origReplaceChildren = Element.prototype.replaceChildren;
  var origInsertBefore = Node.prototype.insertBefore;
  function parseClean(html) {
    var tpl = origCreate.call(D, 'template');
    innerDesc.set.call(tpl, String(html));
    clean(tpl.content, true);
    return tpl.content;
  }
  if (innerDesc && innerDesc.set) {
    lockGetter(Element.prototype, 'innerHTML', innerDesc.get, function (html) {
      if (this instanceof HTMLTemplateElement) { innerDesc.set.call(this, html); clean(this.content, true); return; }
      origReplaceChildren.call(this, parseClean(html));
    });
  }
  var outerDesc = Object.getOwnPropertyDescriptor(Element.prototype, 'outerHTML');
  if (outerDesc && outerDesc.set) {
    lockGetter(Element.prototype, 'outerHTML', outerDesc.get, function (html) {
      var p = this.parentNode; if (!p) return;
      origInsertBefore.call(p, parseClean(html), this); origRemove.call(this);
    });
  }
  lock(Element.prototype, 'insertAdjacentHTML', function (pos, html) {
    var frag = parseClean(html), p = this.parentNode;
    switch (String(pos).toLowerCase()) {
      case 'beforebegin': if (p) origInsertBefore.call(p, frag, this); break;
      case 'afterbegin': origInsertBefore.call(this, frag, this.firstChild); break;
      case 'beforeend': origInsertBefore.call(this, frag, null); break;
      case 'afterend': if (p) origInsertBefore.call(p, frag, this.nextSibling); break;
      default: throw new DOMException('Invalid position', 'SyntaxError');
    }
  });
  ['setHTMLUnsafe', 'setHTML'].forEach(function (n) {
    if (Element.prototype[n]) lock(Element.prototype, n, function (html) { origReplaceChildren.call(this, parseClean(html)); });
    if (W.ShadowRoot && ShadowRoot.prototype[n]) lock(ShadowRoot.prototype, n, function () {});
  });
  if (W.ShadowRoot) {
    var srInner = Object.getOwnPropertyDescriptor(ShadowRoot.prototype, 'innerHTML');
    if (srInner && srInner.set) {
      lockGetter(ShadowRoot.prototype, 'innerHTML', srInner.get, function (html) {
        origReplaceChildren.call(this, parseClean(html));
      });
    }
  }
  if (W.DOMParser) {
    var origParse = DOMParser.prototype.parseFromString;
    lock(DOMParser.prototype, 'parseFromString', function (str, type) {
      var doc = origParse.call(this, str, type);
      if (doc && doc.documentElement) clean(doc.documentElement, false);
      return doc;
    });
  }
  if (W.Document && Document.parseHTMLUnsafe) {
    lock(Document, 'parseHTMLUnsafe', function (html) {
      var doc = new DOMParser().parseFromString(String(html), 'text/html');
      return doc;
    });
  }

  var nodeCount = 0;
  function countNodes() {
    nodeCount = D.getElementsByTagName('*').length;
    if (nodeCount > CFG.maxNodes) post({ t: 'dom', n: nodeCount });
  }
  var mo = new MutationObserver(function (records) {
    for (var i = 0; i < records.length; i++) {
      var r = records[i];
      if (r.type === 'childList') {
        for (var j = 0; j < r.addedNodes.length; j++) {
          var n = r.addedNodes[j];
          if (!clean(n, false)) { if (n.parentNode) origRemove.call(n); } else scanMxc(n);
        }
      } else if (r.type === 'attributes') {
        cleanAttrs(r.target);
        if (r.attributeName === 'src' && r.target.localName === 'img') fixImgSrc(r.target);
      }
    }
    countNodes();
  });
  // С document-start, до body: элементы из статического HTML виджета тоже
  // проходят через наблюдатель, а не только вставленные кодом.
  mo.observe(D.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['contenteditable', 'src', 'formaction', 'ping', 'srcset', 'shadowrootmode'] });

  // ---------- тапы ----------
  // Тап открывает «окно» только на время синхронной обработки события; одно
  // действие на тап (request/openLink/openTelegramLink/copyText делят его).
  var tap = { open: false, used: true, id: 0 };
  var tapSeq = 0, lastPointerUp = 0;
  function openTap(isClick) {
    var now = Date.now();
    if (isClick && now - lastPointerUp < 700 && tap.id) { tap.open = true; }
    else { tapSeq++; tap = { open: true, used: false, id: tapSeq }; }
    if (!isClick) lastPointerUp = now;
    setTimeout(function () { tap.open = false; }, 0);
  }
  W.addEventListener('pointerup', function (e) { if (e.isTrusted) openTap(false); }, true);
  W.addEventListener('click', function (e) { if (e.isTrusted && e.detail > 0) openTap(true); }, true);
  function takeTap() {
    if (tap.open && !tap.used) { tap.used = true; return tap.id; }
    return 0;
  }

  // ---------- состояние ----------
  var S = {
    colorScheme: CFG.colorScheme,
    themeParams: Object.freeze(Object.assign({}, CFG.themeParams)),
    isActive: !!CFG.isActive,
    chatData: CFG.chatData,
    publicData: CFG.publicData,
    inset: Object.freeze(Object.assign({ top: 0, right: 0, bottom: 0, left: 0, cornerRight: 0, cornerLeft: 0 }, CFG.inset))
  };
  var handlers = Object.create(null);
  var EVENTS = ['themeChanged', 'activated', 'deactivated', 'chatDataChanged', 'publicDataChanged', 'contentSafeAreaChanged'];
  EVENTS.forEach(function (e) { handlers[e] = []; });
  var TW = {};
  function fire(type) {
    var list = (handlers[type] || []).slice();
    for (var i = 0; i < list.length; i++) {
      try { list[i].call(TW); } catch (err) { setTimeout(function () { throw err; }, 0); }
    }
  }
  function applyCss(css) {
    var st = D.documentElement.style;
    Object.keys(css).forEach(function (k) { st.setProperty(k, css[k], 'important'); });
  }
  applyCss(CFG.css);

  function utf8Len(s) { return new TextEncoder().encode(s).length; }
  var inFlight = false, reqSeq = 0, pending = Object.create(null);
  var HF = {};
  var IMPACT = ['light', 'medium', 'heavy', 'rigid', 'soft'], NOTIFY = ['error', 'success', 'warning'];
  lock(HF, 'impactOccurred', function (style) {
    if (IMPACT.indexOf(style) < 0) throw new TypeError('Unknown impact style');
    if (!CFG.isPreview) post({ t: 'haptic', kind: 'impact', style: style });
    return HF;
  });
  lock(HF, 'notificationOccurred', function (type) {
    if (NOTIFY.indexOf(type) < 0) throw new TypeError('Unknown notification type');
    if (!CFG.isPreview) post({ t: 'haptic', kind: 'notification', style: type });
    return HF;
  });
  lock(HF, 'selectionChanged', function () {
    if (!CFG.isPreview) post({ t: 'haptic', kind: 'selection' });
    return HF;
  });
  Object.freeze(HF);

  function tgHost(host) {
    host = host.toLowerCase();
    return ['t.me', 'telegram.me', 'telegram.dog'].some(function (h) { return host === h || host.slice(-h.length - 1) === '.' + h; });
  }
  function parseHttps(url) {
    if (typeof url !== 'string' || url.length < 1 || url.length > 256) throw new TypeError('Invalid URL');
    var u;
    try { u = new URL(url); } catch (e) { throw new TypeError('Invalid URL'); }
    if (u.protocol !== 'https:') throw new TypeError('Only https links are allowed');
    if (u.username || u.password) throw new TypeError('Credentials in URL are not allowed');
    return u;
  }
  // Эмуляция профиля: без тапа — NOT_ALLOWED. Настоящий гейт — у хоста.
  function requireTap() {
    var id = takeTap();
    if (!id) throw new WidgetRequestError('NOT_ALLOWED');
    return id;
  }
  function openLink(url) {
    var u = parseHttps(url);
    if (tgHost(u.hostname)) throw new TypeError('Use openTelegramLink for Telegram links');
    if (CFG.isPreview) return;
    post({ t: 'openLink', url: u.href, tap: requireTap() });
  }
  function openTelegramLink(url) {
    var u = parseHttps(url);
    if (!tgHost(u.hostname)) throw new TypeError('Not a Telegram link');
    var name = u.pathname.split('/')[1] || '';
    var known = (CFG.tmeNames || []).indexOf(name.toLowerCase()) >= 0;
    if (CFG.isPreview) return;
    var id = requireTap();
    if (!known) throw new WidgetRequestError('NOT_ALLOWED');
    post({ t: 'openTelegramLink', url: u.href, tap: id });
  }

  var VIEWER = CFG.viewer ? Object.freeze(Object.assign({}, CFG.viewer)) : null;
  var getters = {
    profile: function () { return 1; },
    colorScheme: function () { return S.colorScheme; },
    theme: function () { return S.colorScheme; },
    themeParams: function () { return S.themeParams; },
    isActive: function () { return S.isActive; },
    isPreview: function () { return !!CFG.isPreview; },
    isForward: function () { return !!CFG.isForward; },
    chatType: function () { return CFG.chatType; },
    viewer: function () { return VIEWER; },
    publicData: function () { return S.publicData; },
    chatData: function () { return CFG.isForward ? null : S.chatData; },
    HapticFeedback: function () { return HF; },
    contentSafeAreaInset: function () { return S.inset; },
    wallet: function () { return null; }
  };
  Object.keys(getters).forEach(function (k) { dp(TW, k, { get: getters[k], enumerable: true, configurable: false }); });
  var methods = {
    isProfileAtLeast: function (n) { return typeof n === 'number' && 1 >= n; },
    watchPublicData: function () { if (CFG.isShared && !CFG.isPreview) post({ t: 'watch', on: true }); },
    unwatchPublicData: function () { if (CFG.isShared && !CFG.isPreview) post({ t: 'watch', on: false }); },
    request: function (data, options) {
      if (typeof data !== 'string') throw new TypeError('data must be a string');
      var len = utf8Len(data);
      if (len < 1 || len > 64) throw new TypeError('data must be 1-64 bytes');
      if (options && options.wallet) return Promise.reject(new WidgetRequestError('NOT_ALLOWED'));
      if (CFG.isPreview || !CFG.queriesAllowed) return Promise.reject(new WidgetRequestError('NOT_ALLOWED'));
      if (inFlight) return Promise.reject(new WidgetRequestError('BUSY'));
      var tapId = takeTap();
      if (!tapId && !CFG.backgroundAllowed) return Promise.reject(new WidgetRequestError('NOT_ALLOWED'));
      inFlight = true;
      var id = ++reqSeq;
      return new Promise(function (resolve, reject) {
        pending[id] = { resolve: resolve, reject: reject };
        post({ t: 'request', id: id, data: data, tap: tapId });
      });
    },
    copyText: function (text) {
      if (typeof text !== 'string' || text.length < 1 || text.length > 256) throw new TypeError('text must be 1-256 characters');
      if (CFG.isPreview) return;
      post({ t: 'copyText', text: text, tap: requireTap() });
    },
    openLink: openLink,
    openTelegramLink: openTelegramLink,
    setResizeAnchor: function (edge) {
      if (edge !== 'top' && edge !== 'bottom') throw new TypeError('edge must be "top" or "bottom"');
      post({ t: 'anchor', edge: edge });
    },
    ready: function () { post({ t: 'ready' }); },
    onEvent: function (type, handler) {
      if (typeof handler !== 'function' || !handlers[type]) return;
      if (handlers[type].length >= 16 || handlers[type].indexOf(handler) >= 0) return;
      handlers[type].push(handler);
    },
    offEvent: function (type, handler) {
      var list = handlers[type]; if (!list) return;
      var i = list.indexOf(handler); if (i >= 0) list.splice(i, 1);
    },
    onTheme: function (cb) { methods.onEvent('themeChanged', cb); }
  };
  Object.keys(methods).forEach(function (k) { lock(TW, k, methods[k]); });
  Object.freeze(TW);
  dp(W, 'TelegramWidget', { value: TW, writable: false, configurable: false, enumerable: true });

  // ---------- LizaWidget ----------
  var LIZA = (CFG.liza || []).slice();
  var LW = {};
  lock(LW, 'has', function (feature) { return LIZA.indexOf(feature) >= 0; });
  Object.freeze(LW);
  dp(W, 'LizaWidget', { value: LW, writable: false, configurable: false, enumerable: true });

  // ---------- mxc: картинки через хост ----------
  var mxcSeq = 0, mxcWait = Object.create(null), mxcDone = Object.create(null);
  var srcDesc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
  var origSetAttr = Element.prototype.setAttribute;
  function wantMxc(img, url) {
    if (LIZA.indexOf('mxc') < 0) return;
    if (mxcDone[url]) { srcDesc.set.call(img, mxcDone[url]); return; }
    var id = ++mxcSeq;
    mxcWait[id] = { img: img, url: url };
    post({ t: 'mxc', id: id, url: url });
  }
  function isMxc(v) { return typeof v === 'string' && v.trim().toLowerCase().indexOf('mxc://') === 0; }
  function fixImgSrc(img) {
    var v = origGetAttr.call(img, 'src');
    if (isMxc(v)) { origRemoveAttr.call(img, 'src'); wantMxc(img, v.trim()); }
  }
  function scanMxc(root) {
    if (!root || !root.querySelectorAll) return;
    var list = [];
    if (root.nodeType === 1 && root.hasAttribute('data-tgw-mxc')) list.push(root);
    var found = root.querySelectorAll('[data-tgw-mxc]');
    for (var i = 0; i < found.length; i++) list.push(found[i]);
    list.forEach(function (img) {
      var url = origGetAttr.call(img, 'data-tgw-mxc'); origRemoveAttr.call(img, 'data-tgw-mxc'); wantMxc(img, url);
    });
  }
  if (srcDesc && srcDesc.set) {
    lockGetter(HTMLImageElement.prototype, 'src', srcDesc.get, function (v) {
      if (isMxc(v)) { wantMxc(this, String(v).trim()); return; }
      srcDesc.set.call(this, v);
    });
  }
  lock(Element.prototype, 'setAttribute', function (name, value) {
    var n = String(name).toLowerCase();
    if (this.localName === 'img' && n === 'src' && isMxc(value)) { wantMxc(this, String(value).trim()); return; }
    if (n === 'contenteditable' || n === 'formaction' || n === 'ping' || n === 'srcset') return;
    return origSetAttr.call(this, name, value);
  });

  // ---------- ссылки ----------
  D.addEventListener('click', function (e) {
    var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!a) return;
    e.preventDefault();
    var href = origGetAttr.call(a, 'href') || '';
    if (href.charAt(0) === '#') return;
    try {
      var u = new URL(href, 'https://invalid.invalid/');
      if (u.protocol !== 'https:' || u.hostname === 'invalid.invalid') return;
      if (tgHost(u.hostname)) openTelegramLink(u.href); else openLink(u.href);
    } catch (err) {}
  }, false);
  W.addEventListener('auxclick', function (e) { e.preventDefault(); }, true);
  W.addEventListener('submit', function (e) { e.preventDefault(); }, true);

  // ---------- скрытый виджет: rAF стоит, таймеры не чаще раза в 1 с ----------
  var origSetInterval = W.setInterval, origSetTimeout = W.setTimeout;
  var origRaf = W.requestAnimationFrame;
  var frames = [];
  function flushFrames() {
    var q = frames; frames = [];
    q.forEach(function (cb) { origRaf.call(W, cb); });
  }
  if (origRaf) {
    lock(W, 'requestAnimationFrame', function requestAnimationFrame(cb) {
      if (S.isActive) return origRaf.call(W, cb);
      frames.push(cb);
      return 0;
    });
  }
  lock(W, 'setTimeout', function setTimeout(fn, ms) {
    var args = Array.prototype.slice.call(arguments);
    if (!S.isActive) args[1] = Math.max(1000, +ms || 0);
    return origSetTimeout.apply(W, args);
  });
  lock(W, 'setInterval', function setInterval(fn, ms) {
    var args = Array.prototype.slice.call(arguments);
    if (!S.isActive) args[1] = Math.max(1000, +ms || 0);
    return origSetInterval.apply(W, args);
  });
  var COLOR_META = D.querySelector('meta[name="color-scheme"]');

  // ---------- видимость ----------
  lockGetter(D, 'hidden', function () { return !S.isActive; });
  lockGetter(D, 'visibilityState', function () { return S.isActive ? 'visible' : 'hidden'; });
  lock(D, 'hasFocus', function () { return S.isActive; });

  // ---------- вход от хоста ----------
  function receive(raw) {
    var m;
    try { m = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (e) { return; }
    if (!m || m.s !== SECRET) return;
    switch (m.t) {
      case 'state':
        var chatChanged = !CFG.isForward && m.chatData !== S.chatData;
        var publicChanged = m.publicData !== S.publicData;
        S.chatData = m.chatData; S.publicData = m.publicData;
        if (chatChanged) fire('chatDataChanged');
        if (publicChanged) fire('publicDataChanged');
        break;
      case 'theme':
        S.colorScheme = m.colorScheme;
        S.themeParams = Object.freeze(Object.assign({}, m.themeParams));
        applyCss(m.css);
        if (COLOR_META) origSetAttr.call(COLOR_META, 'content', m.colorScheme);
        fire('themeChanged');
        break;
      case 'active':
        if (!!m.on === S.isActive) break;
        S.isActive = !!m.on;
        lastTick = performance.now();
        if (S.isActive) flushFrames();
        D.dispatchEvent(new Event('visibilitychange'));
        fire(S.isActive ? 'activated' : 'deactivated');
        break;
      case 'inset':
        S.inset = Object.freeze(Object.assign({ top: 0, right: 0, bottom: 0, left: 0, cornerRight: 0, cornerLeft: 0 }, m.inset));
        applyCss(m.css);
        fire('contentSafeAreaChanged');
        break;
      case 'result':
        var p = pending[m.id]; if (!p) break;
        delete pending[m.id]; inFlight = false;
        if (m.ok) p.resolve(Object.freeze({ result: m.result === undefined ? null : m.result }));
        else p.reject(new WidgetRequestError(m.code || 'FAILED'));
        break;
      case 'mxc':
        var w = mxcWait[m.id]; if (!w) break;
        delete mxcWait[m.id];
        if (!m.b64) break;
        try {
          var bin = atob(m.b64), bytes = new Uint8Array(bin.length);
          for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          var url = mxcDone[w.url] || URL.createObjectURL(new Blob([bytes], { type: m.mime || 'image/png' }));
          mxcDone[w.url] = url;
          srcDesc.set.call(w.img, url);
        } catch (e) {}
        break;
    }
  }
  if (webMode) {
    W.addEventListener('message', function (e) { if (e.source === PARENT) receive(e.data); });
  } else {
    lock(W, '__tgwIn', receive);
  }

  // ---------- размер, heartbeat, старт ----------
  var lastH = -1;
  function measure() {
    var b = D.body; if (!b) return;
    var cs = getComputedStyle(b);
    var h = Math.ceil(b.getBoundingClientRect().height + parseFloat(cs.marginTop || 0) + parseFloat(cs.marginBottom || 0));
    if (h !== lastH) { lastH = h; post({ t: 'size', h: h }); }
  }
  // Дрейф между тиками меряет сам шим (performance.now): блокировка видна
  // по факту, а не по времени прихода сообщения в Dart.
  var lastTick = performance.now();
  origSetInterval.call(W, function () {
    var now = performance.now();
    var gap = S.isActive ? now - lastTick : 0;
    lastTick = now;
    post({ t: 'hb', n: nodeCount, gap: Math.round(gap) });
  }, CFG.heartbeatMs);
  if (W.PerformanceObserver) {
    try {
      new PerformanceObserver(function (list) {
        list.getEntries().forEach(function (e) {
          // На Web iframe делит поток со страницей Лизы: observer видит и её
          // долгие задачи (attribution cross-origin-ancestor). Считаем только свои.
          var a = e.attribution && e.attribution[0];
          if (!a || a.name !== 'self') return;
          if (e.duration > CFG.maxTaskMs) post({ t: 'longtask', ms: e.duration });
        });
      }).observe({ type: 'longtask' });
    } catch (e) {}
  }
  D.addEventListener('DOMContentLoaded', function () {
    // Только body: в head лежат наши CSP/charset/viewport, их не трогаем.
    clean(D.body, false);
    scanMxc(D.body);
    countNodes();
    if (W.ResizeObserver) new ResizeObserver(measure).observe(D.body);
    measure();
    post({ t: 'loaded' });
  });
})();
''';
