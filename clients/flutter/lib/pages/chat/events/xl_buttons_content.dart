import 'dart:async';

import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/external_link_web_view.dart';
import 'package:liza/utils/bot_callback.dart';
import 'package:liza/utils/url_launcher.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/matrix.dart';
import 'html_message.dart';

class _XlButton {
  final String index;
  final String title;
  final String? url;

  /// Сервер принимает нажатие событием [botCallbackEventType] (флаг ставит
  /// Liza Bot API). Без флага — номер текстом (кнопки @bo_food, старые сообщения).
  final bool callback;
  const _XlButton({
    required this.index,
    required this.title,
    this.url,
    this.callback = false,
  });
}

/// Открывает url-кнопку бота ВНУТРИ мессенджера (встроенный `ExternalLinkWebView`)
/// для `https`, иначе — внешним лаунчером (fallback).
///
/// Вынесено top-level, чтобы страж проверял РЕАЛЬНУЮ навигацию (а не реплику
/// логики): `ledger:RL-xl-button-url-inapp-webview`.
/// non-https (`matrix.to`/deep-link/`geo:`/`tel:`/`mailto:`/кастом-схемы)
/// обслуживает `UrlLauncher` — `ExternalLinkWebView` пускает только `https` и на
/// прочих схемах молча ничего не делает, иначе кнопка стала бы мёртвой.
Future<void> openXlButtonUrl(BuildContext context, String url) async {
  if (isSafeHttpsUrl(url)) {
    // closeOnPaymentReturn: url-кнопка бота (в т.ч. «Оплатить» с формой Prodamus)
    // после оплаты редиректит на наш urlSuccess/urlReturn. Закрываем webview на
    // этом редиректе, чтобы вернуть пользователя в чат бота, а не показать SPA
    // магазина («Liza Wall»). Для НЕ-платёжных ссылок безвредно (на /payment/*
    // они не ходят).
    await ExternalLinkWebView.open(
      context: context,
      url: url,
      closeOnPaymentReturn: true,
    );
  } else {
    UrlLauncher(context, url).launchUrl();
  }
}

/// Кнопки XL под текстовым сообщением бота (нативный рендер Liza reply_markup).
///
/// Сообщение `m.text` от бота с полем `com.liza.xl_buttons` (список
/// `{index, title, url, callback?}`) и чистым текстом в `com.liza.xl_text_html`.
/// Кнопка-ссылка (есть `url`) открывает URL. Кнопка-действие с `callback: true`
/// шлёт событие нажатия [botCallbackEventType] — бот получает `callback_query`,
/// в ленте ничего не появляется; без флага — свой номер обычным текстом
/// (callback-суррогат `liza-bot-api`).
///
/// [event] — display-событие (после правки — сама правка): кнопки и id для
/// нажатия берутся из него, сервер хранит кнопки и под событием правки.
///
/// Интерактивна (рисует кнопки) ТОЛЬКО когда отправитель — бот (роль `ai`):
/// доверяем управляющие кнопки лишь доверенному отправителю. Иначе — обычный
/// текст (старые клиенты и так рендерят нумерованный список из `formatted_body`).
class XlButtonsContent extends StatefulWidget {
  final Event event;
  final Color textColor;
  final Color linkColor;

  const XlButtonsContent({
    required this.event,
    required this.textColor,
    required this.linkColor,
    super.key,
  });

  /// Поле контента со структурированными кнопками (клиентский рендер).
  static const String contentKey = 'com.liza.xl_buttons';

  /// Поле с чистым HTML текста (без нумерованного списка-фолбэка).
  static const String textHtmlKey = 'com.liza.xl_text_html';

  @override
  State<XlButtonsContent> createState() => _XlButtonsContentState();
}

class _XlButtonsContentState extends State<XlButtonsContent> {
  /// Сколько кнопка ждёт ответа бота после тапа. Ответа может не быть вовсе
  /// (бот не вызвал `answerCallbackQuery`) — тогда спиннер снимается молча.
  static const pendingBound = Duration(seconds: 15);

  /// Debounce url-кнопок и текстового суррогата: второй тап, пока обрабатываем
  /// первый, игнорируем — иначе двойной тап по url-кнопке кладёт ДВА webview в
  /// стек навигации. На callback-кнопки не распространяется: у них ожидание
  /// своё у каждой кнопки ([_pending]).
  bool _busy = false;

  /// Кнопки, ждущие ответа бота (спиннер), по номеру. Остальные кнопки
  /// сообщения нажимаются как обычно.
  final Map<String, PendingBotTap> _pending = {};
  final Map<String, Timer> _pendingTimers = {};

  /// Последняя успешно нажатая кнопка (галочка): событие нажатия в ленте не
  /// видно, без отметки пользователь не понял бы, что тап сработал.
  String? _pickedIndex;

  BotCallbackAnswers get _answers =>
      BotCallbackAnswers.of(widget.event.room.client);

  @override
  void dispose() {
    for (final t in _pendingTimers.values) {
      t.cancel();
    }
    for (final tap in _pending.values) {
      _answers.unregister(tap);
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(XlButtonsContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Бот отредактировал сообщение (display-событие сменилось) — это новый набор
    // кнопок: галочка от прежнего нажатия не должна перескочить на кнопку с тем
    // же номером.
    if (oldWidget.event.eventId != widget.event.eventId) {
      _pickedIndex = null;
    }
  }

  List<_XlButton> _parseButtons() {
    final raw = widget.event.content[XlButtonsContent.contentKey];
    final out = <_XlButton>[];
    if (raw is List) {
      for (final b in raw) {
        if (b is! Map) continue;
        final title = b['title']?.toString() ?? '';
        if (title.isEmpty) continue;
        final url = b['url']?.toString();
        out.add(
          _XlButton(
            index: b['index']?.toString() ?? '',
            title: title,
            url: (url != null && url.isNotEmpty) ? url : null,
            callback: b['callback'] == true,
          ),
        );
      }
    }
    return out;
  }

  void _endPending(String index) {
    _pendingTimers.remove(index)?.cancel();
    final tap = _pending.remove(index);
    if (tap != null) _answers.unregister(tap);
    if (mounted) setState(() {});
  }

  Future<void> _onCallbackTap(_XlButton b) async {
    if (_pending.containsKey(b.index)) return;
    final room = widget.event.room;
    final tap = PendingBotTap(
      tapId: newBotTapId(),
      roomId: room.id,
      eventId: widget.event.eventId,
      index: b.index,
      botMxid: widget.event.senderId,
      onAnswer: (answer) {
        _endPending(b.index);
        if (mounted) _showAnswer(answer);
      },
    );
    // Регистрируем ДО отправки: ответ бота может прийти раньше, чем PUT вернётся.
    _answers.register(tap);
    setState(() => _pending[b.index] = tap);
    _pendingTimers[b.index] = Timer(pendingBound, () => _endPending(b.index));

    final sent = await sendBotCallbackTap(
      room,
      index: b.index,
      eventId: widget.event.eventId,
      tapId: tap.tapId,
    );
    if (!mounted) return;
    if (sent) {
      setState(() => _pickedIndex = b.index);
      return;
    }
    if (identical(_pending[b.index], tap)) _endPending(b.index);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).botButtonTapFailed)),
    );
  }

  /// Ответ бота показываем только нажавшему: текст — всплывающей плашкой,
  /// `show_alert` — диалогом с OK, `url` открываем как url-кнопку.
  Future<void> _showAnswer(BotCallbackAnswer answer) async {
    final text = answer.text;
    if (text != null) {
      if (answer.showAlert) {
        await showOkAlertDialog(
          context: context,
          title: widget.event.senderFromMemoryOrFallback.calcDisplayname(),
          message: text,
          okLabel: L10n.of(context).ok,
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(text)));
      }
    }
    final url = answer.url;
    if (url != null && mounted) await openXlButtonUrl(context, url);
  }

  Future<void> _onTap(_XlButton b) async {
    if (b.url == null && b.callback) return _onCallbackTap(b);
    if (_busy) return;
    _busy = true;
    try {
      if (b.url != null) {
        // Кнопка-ссылка бота (в т.ч. «Оплатить» с готовым payment_url формы
        // Prodamus) открывается ВНУТРИ мессенджера — встроенный webview вместо
        // системного браузера (Liza-паритет для inline url-кнопок; кнопки
        // видны только у доверенных ботов роли `ai`).
        await openXlButtonUrl(context, b.url!);
        return;
      }
      // Кнопка-действие без флага: номер текстом → callback-суррогат эмулятора.
      try {
        await widget.event.room.sendTextEvent(b.index, parseCommands: false);
      } catch (e) {
        Logs().e('[XlButtons] callback send failed: $e');
      }
    } finally {
      _busy = false;
    }
  }

  String _textHtml() {
    final html = widget.event.content[XlButtonsContent.textHtmlKey]?.toString();
    if (html != null && html.isNotEmpty) return html;
    // Фолбэк: экранированное тело (HtmlMessage парсит HTML).
    return widget.event.body
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('\n', '<br>');
  }

  @override
  Widget build(BuildContext context) {
    final fontSize =
        AppSettings.fontSizeFactor.value * AppConfig.messageFontSize;

    final textWidget = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: HtmlMessage(
        html: _textHtml(),
        room: widget.event.room,
        textColor: widget.textColor,
        fontSize: fontSize,
        linkStyle: TextStyle(
          color: widget.linkColor,
          fontSize: fontSize,
          decoration: TextDecoration.underline,
          decorationColor: widget.linkColor,
        ),
        onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
        eventId: widget.event.eventId,
      ),
    );

    final buttons = _parseButtons();
    final senderIsBot = Matrix.of(context).isAiUser(widget.event.senderId);
    if (!senderIsBot || buttons.isEmpty) {
      return textWidget;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        textWidget,
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final b in buttons)
                OutlinedButton.icon(
                  onPressed: () => _onTap(b),
                  icon: _pending.containsKey(b.index)
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : _pickedIndex == b.index
                      ? const Icon(Icons.check, size: 16)
                      : null,
                  label: Text(b.title),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
