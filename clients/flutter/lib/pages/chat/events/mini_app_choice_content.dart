import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/external_link_web_view.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/utils/bot_miniapp_registry.dart';
import 'package:liza/utils/composer_prefill.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/widgets/matrix.dart';

/// Перекодировать выбранное изображение в PNG (даунскейл до 512px) движком
/// Flutter. `dart:ui` декодирует всё, что умеет ОС (на macOS/iOS — avif/heic
/// тоже), а PNG попадает в `supported_media_format` Synapse и потому
/// тумбнейлится. Это критично для АВАТАРА: профиль рисуется через `/thumbnail`,
/// а не `/download`, и Synapse НЕ умеет тумбнейлить avif/heic/svg/jxl → аватар
/// молча падает на букву-заглушку. Возврат null → формат движок не осилил (напр.
/// svg-вектор) → грузим сырьё как есть. ledger:RL-avatar-thumbnailable-png-transcode
@visibleForTesting
Future<Uint8List?> toThumbnailablePng(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 512);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return data?.buffer.asUint8List();
  } catch (e) {
    Logs().w('[MiniAppChoice] png-транскод не удался, грузим сырьё: $e');
    return null;
  }
}

/// Проверка Matrix user ID формата `@name:server` для кнопки open_chat.
bool isValidMatrixUserId(String? value) {
  if (value == null || value.isEmpty) return false;
  final m = RegExp(r'^@[^:\s]+:[^:\s]+$');
  return m.hasMatch(value);
}

/// Карточка-ВЫБОР от бота (онбординг подключения mini App).
///
/// Рендерит сообщение с `msgtype: "com.liza.miniapp.choice"` как карточку с
/// заголовком, описанием и вертикальным стеком кнопок (≤5). Кнопка с
/// `action: "reply"` отправляет боту callback `com.liza.miniapp.callback`
/// (связан с карточкой через `m.relates_to`/`com.liza.miniapp.answer`). Кнопка
/// с `action: "open_url"`/`"open_app"` открывает [MiniAppWebView] без callback.
///
/// Интерактивна (рисует кнопки) ТОЛЬКО когда отправитель — бот (роль `ai`):
/// карточка управляет действиями пользователя, поэтому доверяем её только
/// доверенному отправителю. Для остальных отправителей — fallback на `body`.
class MiniAppChoiceContent extends StatefulWidget {
  final Event event;
  final Timeline timeline;
  final Color textColor;

  const MiniAppChoiceContent({
    required this.event,
    required this.timeline,
    required this.textColor,
    super.key,
  });

  /// msgtype для choice-карточки Mini App.
  static const String msgType = 'com.liza.miniapp.choice';

  /// rel_type, которым callback связывается с карточкой.
  static const String answerRelType = 'com.liza.miniapp.answer';

  /// msgtype callback-события (клиент → комната).
  static const String callbackMsgType = 'com.liza.miniapp.callback';

  @override
  State<MiniAppChoiceContent> createState() => _MiniAppChoiceContentState();
}

class _MiniAppButton {
  final String buttonId;
  final String text;
  final String action;
  final String? url;
  final String? appType;
  final String? mxid;

  /// Текст для предзаполнения поля ввода при нажатии (кнопка «Изменить» службы
  /// поддержки): клиент кладёт его в композер, пользователь правит и отправляет.
  final String? prefill;

  /// `open_chat`: id кнопки, которую клиент «нажимает» в открытом чате
  /// (callback-событие). Сейчас — только основной чат с Лизой: `bf.agent`
  /// стартового меню BotFather шлёт ей `agent.start`.
  final String? callback;

  /// Кнопка половинной ширины: рисуется по две в ряд (грид как в Liza).
  /// По умолчанию false → кнопка занимает всю ширину (вертикальный стек).
  final bool half;

  _MiniAppButton({
    required this.buttonId,
    required this.text,
    required this.action,
    this.url,
    this.appType,
    this.mxid,
    this.prefill,
    this.callback,
    this.half = false,
  });
}

/// Кнопки Лизы, которые карточка ДРУГОГО бота вправе нажать за пользователя.
/// Карточку с `open_chat` на Лизу может прислать и пользовательский бот: без
/// списка один тап отправил бы в основной чат с Лизой любой `button_id` её
/// мастеров. `agent.start` безвреден — сбрасывает мастер и показывает карточку.
const lizaCardCallbacks = {'agent.start'};

/// `open_chat` кнопки карточки бота: открыть личный чат с [mxid].
///
/// Для Лизы — всегда её ОСНОВНОЙ чат: SDK вернул бы самый свежий DM, а им может
/// быть чат-запрос «Лиза: …». С [callback] в этом чате ещё и нажимается кнопка
/// её карточки (`bf.agent` стартового меню BotFather → `agent.start`). У других
/// ботов и вне [lizaCardCallbacks] [callback] игнорируется.
Future<void> openChatFromCard(
  BuildContext context,
  Client client, {
  required String mxid,
  String? callback,
  required String body,
}) async {
  final lizaMxid = MatrixState.lizaMxid;
  if (mxid == lizaMxid && lizaCardCallbacks.contains(callback)) {
    return openLizaAssistantWithCallback(
      context,
      client,
      lizaMxid,
      buttonId: callback!,
      body: body,
    );
  }
  final roomId = mxid == lizaMxid
      ? await ensureLizaAssistantDm(client, lizaMxid)
      : await client.ensureDirectChat(mxid);
  if (context.mounted) context.go('/rooms/$roomId');
}

/// Карточка настроек кнопок быстрого доступа (`choice_id` вида `btncfg_<app_id>`)
/// приходит ПОСЛЕ того, как сервер применил вкл/выкл или переименование кнопки.
/// Её появление — сигнал «настройки кнопок изменились» → клиенту пора перечитать
/// реестр. Вынесено чистой функцией для стража (ledger:RL-bot-miniapp-button-config).
bool isButtonConfigCard(String? choiceId) =>
    choiceId != null && choiceId.startsWith('btncfg_');

class _MiniAppChoiceContentState extends State<MiniAppChoiceContent> {
  /// id кнопки, по которой идёт отправка callback (гард от дабл-клика).
  String? _pending;

  @override
  void initState() {
    super.initState();
    // Настройки кнопок изменились (пришла карточка btncfg_*) → форсим перечитку
    // реестра СРАЗУ, чтобы плашка «Открыть» в списке чатов и кнопка в композере
    // обновили название/видимость без ожидания TTL (эндпоинт /liza/mybots не
    // пушит Matrix-события). scheduleRefresh — страховка от гонки с уже летящим
    // запросом (см. RL-bot-miniapp-button-config).
    if (isButtonConfigCard(_choiceId)) {
      final client = widget.event.room.client;
      BotMiniAppRegistry.instance.ensureLoaded(client, force: true);
      BotMiniAppRegistry.instance.scheduleRefresh(client);
    }
  }

  /// Гард: роль отправителя дозагружаем не более одного раза на виджет.
  bool _roleFetchRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Кнопки-действия карточки рисуются только для ai-отправителя (isAiUser в
    // build). В group-комнате (модерация жалоб) роль отправителя в кэш ролей не
    // попадает — он заполняется лишь для своего юзера / DM-партнёров / поиска —
    // поэтому кнопки пропадают, остаётся body-fallback. Дозагружаем роль
    // отправителя ПО ФАКТУ незагрузки (`getRole == null`), НЕ по `isAiUser==false`
    // (иначе фетч и для обычных юзеров каждый TTL). refreshIfStale уважает TTL,
    // рендер перестроится по rolesVersion (см. build).
    final service = Matrix.of(context).userRoleService;
    final senderId = widget.event.senderId;
    if (!_roleFetchRequested && service.getRole(senderId) == null) {
      _roleFetchRequested = true;
      service.refreshIfStale([senderId]);
    }
  }

  /// id кнопки, выбранной локально в этой сессии (на случай, когда выбор ещё
  /// не виден в timeline — оптимистичная отметка).
  String? _pickedLocal;

  String? get _choiceId => widget.event.content.tryGet<String>('choice_id');

  String get _title {
    final raw = widget.event.content.tryGet<String>('title');
    if (raw == null || raw.isEmpty) return L10n.of(context).miniAppFallbackName;
    return raw.length <= 96 ? raw : raw.substring(0, 96);
  }

  String? get _text {
    final raw = widget.event.content.tryGet<String>('text');
    if (raw == null || raw.isEmpty) return null;
    return raw.length <= 512 ? raw : raw.substring(0, 512);
  }

  List<_MiniAppButton> get _buttons {
    final raw = widget.event.content.tryGetList<Object?>('buttons');
    if (raw == null) return const [];
    final result = <_MiniAppButton>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final buttonId = item['button_id'];
      final text = item['text'];
      if (buttonId is! String || buttonId.isEmpty) continue;
      if (text is! String || text.isEmpty) continue;
      result.add(
        _MiniAppButton(
          buttonId: buttonId,
          text: text.length <= 48 ? text : text.substring(0, 48),
          action: (item['action'] as String?) ?? 'reply',
          url: (item['url'] as String?) ?? (item['app_url'] as String?),
          appType: item['app_type'] as String?,
          mxid: item['mxid'] as String?,
          prefill: item['prefill'] as String?,
          callback: item['callback'] as String?,
          half: item['half'] == true,
        ),
      );
      // Потолок повышен с 5 до 8: detail-карточка /myapps в Liza-стиле несёт до
      // 6 кнопок (Открыть + 4 действия парами + Назад).
      if (result.length >= 8) break;
    }
    return result;
  }

  bool _isValidUrl(String? url) {
    if (url == null) return false;
    final uri = Uri.tryParse(url);
    // host.isNotEmpty: 'https://' проходит scheme-проверку, но открыть нечего —
    // кнопка не должна выглядеть активной и молча не срабатывать (ревью N3).
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  bool _isEnabled(_MiniAppButton button) {
    switch (button.action) {
      case 'reply':
        return true;
      case 'open_url':
      case 'open_app':
      case 'open_link':
        return _isValidUrl(button.url);
      case 'open_chat':
        return isValidMatrixUserId(button.mxid);
      case 'upload_avatar':
        return true;
      default:
        return false;
    }
  }

  /// id последней кнопки, по которой пользователь ответил на ЭТУ карточку.
  /// Используется только для визуальной отметки (галочка/акцент) — кнопки при
  /// этом остаются активными (паритет с Liza: inline-клавиатура не «застывает»
  /// после нажатия, пользователь может вернуться в меню и выбрать другое).
  ///
  /// Приоритет — локальный оптимистичный выбор (`_pickedLocal`): после повторного
  /// нажатия подсветка следует за ПОСЛЕДНИМ выбором в этой сессии. Иначе ищем в
  /// timeline своё событие callback с `m.relates_to.event_id == event.eventId`
  /// (переживает перезапуск и синхронизацию между устройствами).
  String? get _answeredButtonId {
    if (_pickedLocal != null) return _pickedLocal;
    final selfId = widget.event.room.client.userID;
    final cardId = widget.event.eventId;
    if (selfId == null) return null;
    for (final e in widget.timeline.events) {
      if (e.senderId != selfId) continue;
      if (e.content.tryGet<String>('msgtype') !=
          MiniAppChoiceContent.callbackMsgType) {
        continue;
      }
      final relates = e.content.tryGetMap<String, Object?>('m.relates_to');
      if (relates == null) continue;
      if (relates['rel_type'] != MiniAppChoiceContent.answerRelType) continue;
      if (relates['event_id'] != cardId) continue;
      return e.content.tryGet<String>('button_id');
    }
    return null;
  }

  Future<void> _onPressed(_MiniAppButton button) async {
    // Блокируем только время «в полёте» одной отправки (гард от дабл-клика).
    // Уже отвечённую карточку НЕ запираем — кнопки остаются активными, чтобы
    // можно было выбрать другое действие / вернуться в меню (как в Liza).
    if (_pending != null) return;

    switch (button.action) {
      case 'open_chat':
        if (!isValidMatrixUserId(button.mxid) || !mounted) return;
        // `_pending` ОБЯЗАТЕЛЕН и здесь, а не только в ветке 'reply': без него гард
        // выше (`_pending != null`) на open_chat не срабатывает никогда, кнопка не
        // дизейблится и не показывает спиннер. Дедуп самого DM при двух быстрых
        // тапах — в `ensureDirectChat` (utils/direct_chat_ensure.dart).
        setState(() => _pending = button.buttonId);
        try {
          await openChatFromCard(
            context,
            widget.event.room.client,
            mxid: button.mxid!,
            callback: button.callback,
            body: button.text,
          );
        } catch (e) {
          Logs().e('[MiniAppChoice] open_chat failed: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(L10n.of(context).miniAppOpenBotChatFailed),
              ),
            );
          }
        } finally {
          if (mounted) setState(() => _pending = null);
        }
        return;
      case 'open_url':
      case 'open_app':
        if (!_isValidUrl(button.url) || !mounted) return;
        await MiniAppWebView.open(
          context: context,
          appUrl: button.url!,
          appId: widget.event.content.tryGet<String>('app_id') ?? 'unknown',
          appName: _title,
          room: widget.event.room,
          appType: button.appType ?? 'first_party',
        );
        return;
      case 'open_link':
        // Внешняя ссылка (напр. «Стать продавцом» → Яндекс-форма) во ВСТРОЕННОМ
        // лёгком webview — БЕЗ mini-app-контракта (init_data/allowlist/beacon),
        // в отличие от open_url/open_app. См. external_link_web_view.dart.
        if (!_isValidUrl(button.url) || !mounted) return;
        await ExternalLinkWebView.open(context: context, url: button.url!);
        return;
      case 'upload_avatar':
        // «Загрузить из папки» (шаг аватара мастера /newbot): выбираем картинку
        // с диска и отправляем как m.image — бот на шаге аватара её подхватит.
        await _pickAndSendImage(button);
        return;
      case 'reply':
        // «Изменить» службы поддержки: предзаполняем поле ввода прежним текстом
        // обращения (пользователь правит и отправляет). Мост — composerPrefill,
        // т.к. карточка не видит ChatController напрямую.
        if (button.prefill != null && button.prefill!.isNotEmpty) {
          composerPrefill.value = (
            roomId: widget.event.room.id,
            text: button.prefill!,
          );
        }
        final body = L10n.of(context).miniAppChoiceSelected(button.text);
        setState(() => _pending = button.buttonId);
        try {
          await widget.event.room.sendEvent({
            'msgtype': MiniAppChoiceContent.callbackMsgType,
            'body': body,
            'button_id': button.buttonId,
            if (_choiceId != null) 'choice_id': _choiceId,
            'm.relates_to': {
              'rel_type': MiniAppChoiceContent.answerRelType,
              'event_id': widget.event.eventId,
            },
          });
          if (mounted) {
            setState(() {
              _pickedLocal = button.buttonId;
              _pending = null;
            });
          }
          // Привязали app к боту → обновляем реестр, чтобы «Открыть»/«Миниапп»
          // у бота появились сразу, а не по TTL (эндпоинт не пушит события).
          if (button.buttonId.startsWith('myapps.attach.pick.')) {
            BotMiniAppRegistry.instance
                .scheduleRefresh(widget.event.room.client);
          }
        } catch (e) {
          Logs().e('[MiniAppChoice] callback send failed: $e');
          if (mounted) setState(() => _pending = null);
        }
        return;
    }
  }

  /// MIME по расширению (без пакета mime — держим зависимости минимальными).
  static String _imageMime(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const map = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'jfif': 'image/jpeg',
      'png': 'image/png', 'apng': 'image/apng', 'gif': 'image/gif',
      'webp': 'image/webp', 'heic': 'image/heic', 'heif': 'image/heif',
      'avif': 'image/avif', 'bmp': 'image/bmp', 'tif': 'image/tiff',
      'tiff': 'image/tiff', 'ico': 'image/x-icon', 'svg': 'image/svg+xml',
      'jxl': 'image/jxl',
    };
    return map[ext] ?? 'application/octet-stream';
  }


  /// Выбор картинки с диска (файловый пикер) и отправка как m.image в комнату.
  /// FileType.custom+whitelist — на macOS FileType.image (file_picker 10.x)
  /// серит часть форматов, поэтому берём любой. Выбранное перекодируем в PNG
  /// (`toThumbnailablePng`), чтобы аватар бота тумбнейлился на Synapse; если
  /// движок формат не осилил — грузим сырые байты. Бот на шаге
  /// WAITING_FOR_AVATAR берёт mxc из этого m.image.
  Future<void> _pickAndSendImage(_MiniAppButton button) async {
    if (_pending != null) return;
    setState(() => _pending = button.buttonId);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'jpg', 'jpeg', 'jfif', 'png', 'apng', 'gif', 'webp',
          'heic', 'heif', 'avif', 'bmp', 'tif', 'tiff', 'ico', 'svg', 'jxl',
        ],
        withData: true,
      );
      final files = result?.files ?? const [];
      if (files.isEmpty || files.first.bytes == null || !mounted) return;
      final rawBytes = files.first.bytes!;
      final png = await toThumbnailablePng(rawBytes);
      if (!mounted) return;
      final Uint8List bytes;
      final String name;
      final String mime;
      if (png != null) {
        bytes = png;
        name = 'avatar.png';
        mime = 'image/png';
      } else {
        bytes = rawBytes;
        name = files.first.name;
        mime = _imageMime(name);
      }
      final client = widget.event.room.client;
      final uri = await client.uploadContent(bytes, filename: name, contentType: mime);
      await widget.event.room.sendEvent({
        'msgtype': 'm.image',
        'body': name,
        'url': uri.toString(),
        'info': {'mimetype': mime, 'size': bytes.length},
      });
    } catch (e) {
      Logs().e('[MiniAppChoice] avatar upload failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).miniAppUploadImageFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Кнопки видны только для ai-отправителя (isAiUser в _buildContent). Роль
    // отправителя грузится асинхронно (didChangeDependencies) — перестраиваемся по
    // rolesVersion, иначе в group-комнате кнопки не появятся даже после загрузки
    // роли (виджет уже построен). Идиом «оберни role-зависимый фрагмент» —
    // if_developer.dart:19, user_role_badge.dart:46.
    return ValueListenableBuilder<int>(
      valueListenable: Matrix.of(context).userRoleService.rolesVersion,
      builder: (context, _, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final buttons = _buttons;
    final senderIsBot = Matrix.of(context).isAiUser(widget.event.senderId);

    // Fallback на body: нет кнопок ИЛИ отправитель не бот (карточке-выбору от
    // недоверенного отправителя кнопки не рисуем — она управляет действиями).
    if (buttons.isEmpty || !senderIsBot) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          widget.event.body,
          style: TextStyle(
            color: widget.textColor,
            fontSize: 14,
            height: 1.35,
          ),
        ),
      );
    }

    final answeredId = _answeredButtonId;

    // Liza-стиль: полупрозрачный «пузырь» текста + ПЛОСКАЯ inline-клавиатура
    // под ним. Без жёсткой белой карточки/тени/рамки — блок сливается с фоном
    // чата (msgtype исключён из пузыря чата в message.dart → noBubble).
    final bubbleColor = isDark
        ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
        : Colors.white.withValues(alpha: 0.62);
    final titleColor = colorScheme.onSurface;
    final textColor = colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Пузырь текста (заголовок + описание) — полупрозрачный, как
            // сообщение бота в Liza.
            Container(
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.circular(AppConfig.borderRadius),
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      height: 1.25,
                      color: titleColor,
                    ),
                  ),
                  if (_text != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _text!,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.35,
                        color: textColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 6),

            // Inline-клавиатура: half-кнопки по две в ряд, остальные на всю
            // ширину. Первая кнопка — акцентная (текст primary).
            MiniAppButtonGrid(
              buttons: [
                for (var i = 0; i < buttons.length; i++)
                  MiniAppGridButton(
                    label: buttons[i].text,
                    half: buttons[i].half,
                    accent: i == 0,
                    loading: _pending == buttons[i].buttonId,
                    picked: answeredId == buttons[i].buttonId,
                    // Disabled только пока идёт отправка любой кнопки, или сам
                    // action недоступен. Ответ на карточку кнопки НЕ гасит —
                    // остаются активными для возврата в меню (паритет с Liza).
                    disabled: _pending != null || !_isEnabled(buttons[i]),
                    onPressed: () => _onPressed(buttons[i]),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Спецификация одной кнопки грида (без зависимости от Matrix/Event) — чтобы
/// раскладку можно было рендерить и тестировать отдельно от choice-карточки.
class MiniAppGridButton {
  final String label;

  /// Половинная ширина: по две в ряд (грид как inline-клавиатура Liza).
  final bool half;
  final bool accent;
  final bool loading;
  final bool picked;
  final bool disabled;
  final VoidCallback onPressed;

  const MiniAppGridButton({
    required this.label,
    required this.onPressed,
    this.half = false,
    this.accent = false,
    this.loading = false,
    this.picked = false,
    this.disabled = false,
  });
}

/// Грид кнопок mini App в стиле inline-клавиатуры Liza: ``half``-кнопки
/// пакуются по две в ряд, остальные занимают ряд целиком. Одиночная ``half`` в
/// конце группы растягивается на всю ширину (без «дырки»). Чистая презентация —
/// без Matrix-контекста, поэтому рендерится и снимается в виджет-тестах.
class MiniAppButtonGrid extends StatelessWidget {
  final List<MiniAppGridButton> buttons;

  const MiniAppButtonGrid({required this.buttons, super.key});

  /// Группировка индексов кнопок в ряды по флагам ``half``. Вынесена отдельно
  /// (pure) ради детерминированного теста раскладки. Пример: для
  /// ``[false, true, true, true, true, false]`` → ``[[0],[1,2],[3,4],[5]]``.
  static List<List<int>> rows(List<bool> half) {
    final result = <List<int>>[];
    final pending = <int>[];
    void flush() {
      if (pending.isEmpty) return;
      result.add(List.of(pending));
      pending.clear();
    }

    for (var i = 0; i < half.length; i++) {
      if (half[i]) {
        pending.add(i);
        if (pending.length == 2) flush();
      } else {
        flush();
        result.add([i]);
      }
    }
    flush();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final rowsIdx = rows(buttons.map((b) => b.half).toList());

    Widget cell(int i) {
      final b = buttons[i];
      return _MiniAppChoiceButton(
        colorScheme: colorScheme,
        label: b.label,
        loading: b.loading,
        accent: b.accent,
        isPicked: b.picked,
        disabled: b.disabled,
        onPressed: b.onPressed,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < rowsIdx.length; r++) ...[
          if (rowsIdx[r].length == 2)
            // IntrinsicHeight + stretch: обе кнопки ряда получают одинаковую
            // высоту (по самой высокой). Иначе однострочная кнопка («Мои боты»)
            // выходит ниже двухстрочной соседки («Мои приложения») — LABA-2198.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: cell(rowsIdx[r][0])),
                  const SizedBox(width: 10),
                  Expanded(child: cell(rowsIdx[r][1])),
                ],
              ),
            )
          else
            cell(rowsIdx[r][0]),
          if (r != rowsIdx.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// Кнопка-«таблетка» внутри карточки-выбора Mini App.
///
/// Отдельный StatefulWidget ради hover-состояния (десктоп) и плавных
/// анимаций фона/границы. Вся бизнес-логика (что делает нажатие) остаётся в
/// родителе — сюда приходит готовый [onPressed] и набор флагов состояния.
class _MiniAppChoiceButton extends StatefulWidget {
  final ColorScheme colorScheme;
  final String label;
  final bool loading;
  final bool accent;
  final bool isPicked;
  final bool disabled;
  final VoidCallback onPressed;

  const _MiniAppChoiceButton({
    required this.colorScheme,
    required this.label,
    required this.loading,
    required this.accent,
    required this.isPicked,
    required this.disabled,
    required this.onPressed,
  });

  @override
  State<_MiniAppChoiceButton> createState() => _MiniAppChoiceButtonState();
}

class _MiniAppChoiceButtonState extends State<_MiniAppChoiceButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = widget.colorScheme;
    final isDark = cs.brightness == Brightness.dark;
    final disabled = widget.disabled;
    final picked = widget.isPicked;

    // Плоская полупрозрачная заливка как у inline-кнопок Liza: без рамки и
    // тени, фон чата слегка просвечивает. Наведение/нажатие усиливают заливку.
    final Color fillColor;
    final Color contentColor;

    if (picked) {
      fillColor = cs.primary.withValues(alpha: isDark ? 0.32 : 0.16);
      contentColor = cs.primary;
    } else if (disabled) {
      fillColor = cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.035);
      contentColor = cs.onSurfaceVariant.withValues(alpha: 0.5);
    } else {
      final base = isDark ? 0.12 : 0.07;
      final boost = _pressed
          ? (isDark ? 0.12 : 0.09)
          : _hovered
              ? (isDark ? 0.06 : 0.05)
              : 0.0;
      fillColor = cs.onSurface.withValues(alpha: base + boost);
      // Первая (основная) кнопка — текст primary, как «Open» в Liza.
      contentColor = widget.accent ? cs.primary : cs.onSurface;
    }

    final radius = BorderRadius.circular(AppConfig.borderRadius * 0.5);

    final inner = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      constraints: const BoxConstraints(minHeight: 44),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: radius,
        // Светлая тонкая кромка — «блик» стекла/зеркала поверх матового фона.
        border: Border.all(
          color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.5),
          width: 0.8,
        ),
      ),
      child: widget.loading
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.primary,
              ),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (picked) ...[
                  Icon(Icons.check_rounded, size: 18, color: contentColor),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    widget.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: contentColor,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
    );

    // «Матовое стекло» (frosted glass): размываем фон чата под кнопкой + светлая
    // кромка выше → эффект полупрозрачного стекла/зеркала (по запросу UX).
    final child = ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: inner,
      ),
    );

    // Лёгкое «утопление» при нажатии — приятный тактильный отклик.
    final scaled = AnimatedScale(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      scale: _pressed && !disabled ? 0.98 : 1.0,
      child: child,
    );

    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: disabled ? null : (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
        onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        // Ripple поверх кастомного фона — Material с прозрачным цветом.
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: disabled ? null : widget.onPressed,
            splashColor: cs.primary.withValues(alpha: 0.12),
            highlightColor: Colors.transparent,
            hoverColor: Colors.transparent,
            child: scaled,
          ),
        ),
      ),
    );
  }
}
