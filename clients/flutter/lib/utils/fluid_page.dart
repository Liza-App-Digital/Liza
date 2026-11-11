import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';

/// Ключ маркера «жидкой» страницы в содержимом события: `{title, sha256}`.
const String kFluidPageKey = 'com.liza.page';

/// Потолок размера страницы: разметка модели ≤150 КБ плюс до 4 встроенных
/// фото (data:-URI) — бот режет на 1,5 МБ, клиент не верит и проверяет сам.
const int kFluidPageMaxBytes = 1500000;

/// Маркер хода сборки страницы в обещании бота:
/// `{stage, started (ms), of (eventId обещания — в правках)}`.
const String kFluidPagePendingKey = 'com.liza.page_pending';

/// Обещание, не дошедшее до done/failed за это время, считаем сорвавшимся
/// (бот упал или перезапущен посреди сборки): бюджет бота ~3,5 мин.
const Duration kFluidPagePendingStale = Duration(minutes: 6);

enum FluidPageStage { answer, photos, layout, done, failed }

/// Состояние сборки страницы из обещания (исходного события, его правки или
/// display-события с подставленной правкой).
class FluidPagePending {
  /// eventId исходного обещания — им же помечена страница (`pending`).
  final String id;
  final FluidPageStage stage;
  final DateTime started;

  const FluidPagePending({
    required this.id,
    required this.stage,
    required this.started,
  });

  bool get finished =>
      stage == FluidPageStage.done || stage == FluidPageStage.failed;

  /// Этап с учётом протухания: незавершённое дольше [kFluidPagePendingStale]
  /// — сорвалось.
  FluidPageStage stageAt(DateTime now) =>
      !finished && now.difference(started) > kFluidPagePendingStale
      ? FluidPageStage.failed
      : stage;
}

/// Ход сборки из события; null — не обещание страницы. Для правки берётся
/// `m.new_content` (там актуальный маркер), id — из `of`.
FluidPagePending? fluidPagePending(Event event) {
  if (event.type != EventTypes.Message || event.redacted) return null;
  final marker =
      event.content
          .tryGetMap<String, Object?>('m.new_content')
          ?.tryGetMap<String, Object?>(kFluidPagePendingKey) ??
      event.content.tryGetMap<String, Object?>(kFluidPagePendingKey);
  if (marker == null) return null;
  final stage = FluidPageStage.values
      .where((s) => s.name == marker.tryGet<String>('stage'))
      .firstOrNull;
  if (stage == null) return null;
  final startedMs = marker.tryGet<int>('started');
  return FluidPagePending(
    id: marker.tryGet<String>('of') ?? event.eventId,
    stage: stage,
    started: startedMs != null
        ? DateTime.fromMillisecondsSinceEpoch(startedMs)
        : event.originServerTs,
  );
}

/// eventId обещания, которое закрывает эта страница, иначе null.
String? fluidPagePendingOf(Event event) => event.content
    .tryGetMap<String, Object?>(kFluidPageKey)
    ?.tryGet<String>('pending');

/// Content-Security-Policy страницы. `script-src` не задан → `default-src 'none'`
/// запрещает JS целиком; сеть закрыта (`connect-src`, `img-src` только `data:`).
const String kFluidPageCsp =
    "default-src 'none'; style-src 'unsafe-inline'; img-src data:; "
    "font-src data:; connect-src 'none'; form-action 'none'; base-uri 'none'";

/// Событие — HTML-страница ответа бота: `m.file` text/html с маркером
/// [kFluidPageKey]. Отправителя проверяет вызывающий (см. [isFluidPageSender]).
bool isFluidPageEvent(Event event) {
  if (event.type != EventTypes.Message || event.redacted) return false;
  if (event.messageType != MessageTypes.File) return false;
  final mimetype = event.content.tryGetMap<String, Object?>(
    'info',
  )?['mimetype'];
  if (mimetype != 'text/html') return false;
  return fluidPageSha256(event) != null;
}

/// Название страницы из маркера (до 60 символов), иначе пусто.
String fluidPageTitle(Event event) {
  final title = event.content
      .tryGetMap<String, Object?>(kFluidPageKey)
      ?.tryGet<String>('title')
      ?.trim();
  if (title == null || title.isEmpty) return '';
  return title.length > 60 ? title.substring(0, 60) : title;
}

String? fluidPageSha256(Event event) {
  final sha = event.content
      .tryGetMap<String, Object?>(kFluidPageKey)
      ?.tryGet<String>('sha256');
  return sha != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ? sha : null;
}

/// Страницу строит бот чата: отправитель — бот/ИИ-аккаунт, не сам пользователь
/// и не чужой участник группы.
bool isFluidPageSender(
  Event event, {
  required bool Function(String userId) isBotOrAiUser,
}) =>
    event.senderId != event.room.client.userID && isBotOrAiUser(event.senderId);

/// Строка превью в списке чатов для страницы от бота: название страницы
/// (пусто — страница без названия); не страница или не от бота — null,
/// и превью строится как для обычного сообщения.
String? fluidPagePreviewTitle(
  Event? event, {
  required bool Function(String userId) isBotOrAiUser,
}) {
  if (event == null || !isFluidPageEvent(event)) return null;
  if (!isFluidPageSender(event, isBotOrAiUser: isBotOrAiUser)) return null;
  return fluidPageTitle(event);
}

/// Документ для WebView: CSP — первым элементом, до любого содержимого модели.
/// Её doctype снимаем и ставим свой, чтобы meta не оказалась перед doctype
/// (иначе quirks-режим).
String fluidPageDocument(String html) {
  final body = html.replaceFirst(
    RegExp(r'^\s*<!doctype[^>]*>', caseSensitive: false),
    '',
  );
  return '<!doctype html><meta http-equiv="Content-Security-Policy" '
      'content="$kFluidPageCsp">$body';
}

class FluidPageException implements Exception {
  final String reason;
  const FluidPageException(this.reason);
  @override
  String toString() => 'FluidPageException($reason)';
}

/// Скачивает файл страницы (с расшифровкой в E2EE-комнате), сверяет sha256 с
/// маркером и размер; отдаёт HTML. [download] подменяется в тестах.
Future<String> loadFluidPageHtml(
  Event event, {
  Future<Uint8List> Function(Event event)? download,
}) async {
  final expected = fluidPageSha256(event);
  if (expected == null) throw const FluidPageException('no-marker');
  final Uint8List bytes;
  try {
    bytes = download != null
        ? await download(event)
        : (await event.downloadAndDecryptAttachmentHealed()).bytes;
  } catch (e) {
    throw FluidPageException('download: ${e.runtimeType}');
  }
  if (bytes.length > kFluidPageMaxBytes) {
    throw const FluidPageException('too-large');
  }
  if (sha256.convert(bytes).toString() != expected) {
    throw const FluidPageException('sha256-mismatch');
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Фото, вшитое в страницу (`<img src="data:…">`).
class FluidPageImage {
  final Uint8List bytes;
  final String alt;

  const FluidPageImage({required this.bytes, required this.alt});
}

/// Превью страницы для ленты: её фото и первый абзац текста.
class FluidPagePreview {
  final List<FluidPageImage> images;
  final String summary;

  const FluidPagePreview({required this.images, required this.summary});

  static const empty = FluidPagePreview(images: [], summary: '');
}

/// Сколько фото страницы показываем в превью (бот вшивает не больше 4).
const int kFluidPagePreviewMaxImages = 4;

final _imgTag = RegExp(r'<img\b[^>]*>', caseSensitive: false);
final _dataSrc = RegExp(
  r'''\bsrc\s*=\s*["']data:image/(?:jpeg|png|webp);base64,([A-Za-z0-9+/=\s]+)["']''',
  caseSensitive: false,
);
final _altAttr = RegExp(r'''\balt\s*=\s*(["'])(.*?)\1''', caseSensitive: false);
final _paragraphOpen = RegExp(r'<p\b[^>]*>', caseSensitive: false);
final _paragraphClose = RegExp(r'</p\s*>', caseSensitive: false);

/// Тела абзацев `<p …>…</p>` одним проходом. Ленивый dotAll-regex на странице
/// с незакрытыми `<p>` для каждого из них досматривал до конца документа
/// (квадратично на сотнях КБ); здесь каждый символ просматривается O(1) раз.
Iterable<String> _paragraphs(String html) sync* {
  var from = 0;
  while (true) {
    final open = _firstFrom(_paragraphOpen, html, from);
    if (open == null) return;
    final close = _firstFrom(_paragraphClose, html, open.end);
    if (close == null) return;
    yield html.substring(open.end, close.start);
    from = close.end;
  }
}

Match? _firstFrom(RegExp re, String s, int start) {
  final it = re.allMatches(s, start).iterator;
  return it.moveNext() ? it.current : null;
}

final _anyTag = RegExp(r'<[^>]+>');

String _htmlText(String html) => html
    .replaceAll(_anyTag, ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Фото и первый содержательный абзац из HTML страницы. Битые/чужие картинки
/// (не data:-URI jpeg/png/webp) пропускаются — сеть в странице закрыта CSP,
/// внешних src там быть не может.
FluidPagePreview parseFluidPagePreview(String html) {
  final images = <FluidPageImage>[];
  for (final tag in _imgTag.allMatches(html)) {
    if (images.length == kFluidPagePreviewMaxImages) break;
    final src = _dataSrc.firstMatch(tag[0]!);
    if (src == null) continue;
    final Uint8List bytes;
    try {
      bytes = base64.decode(src[1]!.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      continue;
    }
    if (bytes.isEmpty) continue;
    final alt = _altAttr.firstMatch(tag[0]!)?[2] ?? '';
    images.add(FluidPageImage(bytes: bytes, alt: _htmlText(alt)));
  }
  var summary = '';
  for (final body in _paragraphs(html)) {
    final text = _htmlText(body);
    // Подпись под фото («Фото: автор, лицензия») — не содержание страницы.
    if (text.length >= 40 && !text.startsWith('Фото:')) {
      summary = text;
      break;
    }
  }
  return FluidPagePreview(images: images, summary: summary);
}
