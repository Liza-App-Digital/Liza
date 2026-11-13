import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_registry.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/utils/date_time_extension.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';

/// Быстрое действие над капсулой: имя — сегмент пути
/// `POST /liza/chat-capsules/{id}/{action}` и ключ в `actions` ответа списка.
enum ChatCapsuleAction { publish, unpublish, archive, restore }

/// Капсула созвона, привязанная к чату (ответ `GET /liza/chat-capsules`).
class ChatCapsule {
  final String id;
  final String title;
  final DateTime? startedAt;
  final int? durationSec;

  /// Действия, разрешённые сервером (`actions.<name> == true`). Старый сервер
  /// поля не шлёт — набор пуст, меню нет.
  final Set<ChatCapsuleAction> actions;

  const ChatCapsule({
    required this.id,
    required this.title,
    this.startedAt,
    this.durationSec,
    this.actions = const {},
  });
}

class ChatCapsules {
  final String appId;
  final List<ChatCapsule> items;

  const ChatCapsules(this.appId, this.items);
}

/// Разбор ответа liza-bot-api. `null` — раздел не показываем: капсулы выключены или
/// у человека нет почты (мини-апп капсул его всё равно не впустит).
ChatCapsules? parseChatCapsules(Map<String, dynamic> data) {
  final appId = data['app_id'];
  if (appId is! String || appId.isEmpty || data['reason'] != null) return null;
  final rows = data['capsules'];
  if (rows is! List) return null;
  final items = <ChatCapsule>[];
  for (final r in rows) {
    if (r is! Map) continue;
    final id = r['id'];
    if (id is! String || id.isEmpty) continue;
    final title = r['title'];
    final started = r['started_at'];
    final duration = r['duration_sec'];
    final rawActions = r['actions'];
    items.add(
      ChatCapsule(
        id: id,
        title: title is String && title.isNotEmpty ? title : id,
        startedAt: started is String ? DateTime.tryParse(started) : null,
        durationSec: duration is num ? duration.toInt() : null,
        actions: {
          if (rawActions is Map)
            for (final a in ChatCapsuleAction.values)
              if (rawActions[a.name] == true) a,
        },
      ),
    );
  }
  return ChatCapsules(appId, items);
}

typedef ChatCapsulesLoader = Future<ChatCapsules?> Function(Room room);

/// Адрес и заголовки запроса к `/liza/chat-capsules…` от имени человека;
/// `null` — клиент не залогинен.
({Uri url, Map<String, String> headers})? _capsulesRequest(
  Room room,
  String path,
) {
  final client = room.client;
  final host = client.homeserver?.host;
  final token = client.accessToken;
  if (host == null || host.isEmpty || token == null) return null;
  final base = AppConfig.lizaBotApiBaseForHomeserver(host);
  return (
    url: Uri.parse(
      '$base/liza/chat-capsules$path',
    ).replace(queryParameters: {'room_id': room.id}),
    headers: {
      'Authorization': 'Bearer $token',
      if (client.homeserver != null)
        'X-Liza-Homeserver': client.homeserver!.toString(),
    },
  );
}

Future<ChatCapsules?> loadChatCapsules(Room room) async {
  final req = _capsulesRequest(room, '');
  if (req == null) return null;
  try {
    final resp = await http
        .get(req.url, headers: req.headers)
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(utf8.decode(resp.bodyBytes));
    return data is Map<String, dynamic> ? parseChatCapsules(data) : null;
  } catch (e) {
    Logs().w('[ChatCapsules] load failed: $e');
    return null;
  }
}

enum ChatCapsuleActionStatus { ok, forbidden, unavailable, failed }

class ChatCapsuleActionResult {
  final ChatCapsuleActionStatus status;

  /// Текст сервера для 404/409/422: строковый `detail` или `detail.message`.
  final String? detail;

  /// `detail.code`, когда сервис капсул отдал `detail` объектом.
  final String? code;

  const ChatCapsuleActionResult(this.status, [this.detail, this.code]);
}

typedef ChatCapsuleActionRunner =
    Future<ChatCapsuleActionResult> Function(
      Room room,
      String capsuleId,
      ChatCapsuleAction action,
    );

Future<ChatCapsuleActionResult> postChatCapsuleAction(
  Room room,
  String capsuleId,
  ChatCapsuleAction action, {
  http.Client? httpClient,
}) async {
  final req = _capsulesRequest(
    room,
    '/${Uri.encodeComponent(capsuleId)}/${action.name}',
  );
  if (req == null) {
    return const ChatCapsuleActionResult(ChatCapsuleActionStatus.failed);
  }
  final client = httpClient ?? http.Client();
  try {
    final resp = await client
        .post(req.url, headers: req.headers)
        .timeout(const Duration(seconds: 20));
    final code = resp.statusCode;
    if (code >= 200 && code < 300) {
      return const ChatCapsuleActionResult(ChatCapsuleActionStatus.ok);
    }
    if (code == 403) {
      return const ChatCapsuleActionResult(ChatCapsuleActionStatus.forbidden);
    }
    if (code == 502 || code == 503) {
      return const ChatCapsuleActionResult(ChatCapsuleActionStatus.unavailable);
    }
    if (code == 404 || code == 409 || code == 422) {
      final (:message, code: errorCode) = _detail(resp);
      return ChatCapsuleActionResult(
        ChatCapsuleActionStatus.failed,
        message,
        errorCode,
      );
    }
    return const ChatCapsuleActionResult(ChatCapsuleActionStatus.failed);
  } catch (e) {
    Logs().w('[ChatCapsules] ${action.name} failed: $e');
    return const ChatCapsuleActionResult(ChatCapsuleActionStatus.failed);
  } finally {
    if (httpClient == null) client.close();
  }
}

/// `detail` бывает строкой или объектом `{code, message?}` (сервис капсул,
/// мост отдаёт его ответ как есть).
({String? message, String? code}) _detail(http.Response resp) {
  String? nonEmpty(Object? v) => v is String && v.isNotEmpty ? v : null;
  try {
    final data = jsonDecode(utf8.decode(resp.bodyBytes));
    final detail = data is Map ? data['detail'] : null;
    if (detail is Map) {
      return (
        message: nonEmpty(detail['message']),
        code: nonEmpty(detail['code']),
      );
    }
    return (message: nonEmpty(detail), code: null);
  } catch (_) {
    return (message: null, code: null);
  }
}

/// Раздел «Капсулы созвонов» в деталях чата: капсулы, привязанные к чату, открываются
/// в мини-аппе капсул (`?capsule=<id>`), «Все капсулы чата» — его список (`?room=1`).
class ChatCapsulesSection extends StatefulWidget {
  final Room room;
  final ChatCapsulesLoader loader;
  final ChatCapsuleActionRunner runAction;

  const ChatCapsulesSection({
    required this.room,
    this.loader = loadChatCapsules,
    this.runAction = postChatCapsuleAction,
    super.key,
  });

  static const int maxShown = 5;

  @override
  State<ChatCapsulesSection> createState() => _ChatCapsulesSectionState();
}

class _ChatCapsulesSectionState extends State<ChatCapsulesSection> {
  late Future<ChatCapsules?> _future = widget.loader(widget.room);

  /// Капсулы, по которым идёт запрос: меню на них заменено индикатором,
  /// повторное нажатие невозможно.
  final Set<String> _busy = {};

  String _actionLabel(L10n l10n, ChatCapsuleAction a) => switch (a) {
    ChatCapsuleAction.publish => l10n.publish,
    ChatCapsuleAction.unpublish => l10n.chatCapsuleUnpublish,
    ChatCapsuleAction.archive => l10n.chatCapsuleArchive,
    ChatCapsuleAction.restore => l10n.chatCapsuleRestore,
  };

  Future<void> _runAction(ChatCapsule c, ChatCapsuleAction action) async {
    if (_busy.contains(c.id)) return;
    final l10n = L10n.of(context);
    if (action == ChatCapsuleAction.archive) {
      final confirmed = await showOkCancelAlertDialog(
        context: context,
        title: l10n.chatCapsuleArchiveConfirm,
        message: c.title,
        okLabel: l10n.chatCapsuleArchive,
        cancelLabel: l10n.cancel,
        isDestructive: true,
      );
      if (confirmed != OkCancelResult.ok || !mounted) return;
    }
    setState(() => _busy.add(c.id));
    final result = await widget.runAction(widget.room, c.id, action);
    if (!mounted) return;
    setState(() {
      _busy.remove(c.id);
      if (result.status == ChatCapsuleActionStatus.ok) {
        _future = widget.loader(widget.room);
      }
    });
    final error = switch (result.status) {
      ChatCapsuleActionStatus.ok => null,
      ChatCapsuleActionStatus.forbidden => l10n.chatCapsuleNoPermission,
      ChatCapsuleActionStatus.unavailable => l10n.chatCapsulesUnavailable,
      ChatCapsuleActionStatus.failed =>
        result.code == 'no_folder'
            ? l10n.chatCapsuleNoFolder
            : result.detail ?? l10n.oopsSomethingWentWrong,
    };
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Widget? _actionsMenu(L10n l10n, ChatCapsule c) {
    if (c.actions.isEmpty) return null;
    if (_busy.contains(c.id)) {
      return const SizedBox.square(
        dimension: 24,
        child: Padding(
          padding: EdgeInsets.all(2),
          child: CircularProgressIndicator.adaptive(strokeWidth: 2),
        ),
      );
    }
    return PopupMenuButton<ChatCapsuleAction>(
      icon: const Icon(Icons.more_horiz),
      tooltip: l10n.more,
      onSelected: (a) => _runAction(c, a),
      itemBuilder: (_) => [
        for (final a in ChatCapsuleAction.values)
          if (c.actions.contains(a))
            PopupMenuItem(value: a, child: Text(_actionLabel(l10n, a))),
      ],
    );
  }

  Future<void> _open(ChatCapsules data, String startPath) async {
    CatalogApp? app;
    try {
      final catalog = await MiniAppRegistry.instance.fetch(widget.room.client);
      for (final a in catalog) {
        if (a.appId == data.appId) app = a;
      }
    } catch (e) {
      Logs().w('[ChatCapsules] каталог не загрузился: $e');
    }
    if (!mounted) return;
    if (app == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).miniAppLoadFailed)),
      );
      return;
    }
    await MiniAppWebView.open(
      context: context,
      appUrl: app.url,
      appId: app.appId,
      appName: app.name,
      room: widget.room,
      appType: app.type,
      appStartPath: startPath,
    );
  }

  String _subtitle(BuildContext context, ChatCapsule c) {
    final parts = [
      if (c.startedAt != null) c.startedAt!.toLocal().localizedTime(context),
      if (c.durationSec != null && c.durationSec! > 0)
        L10n.of(context).chatCapsuleMinutes((c.durationSec! / 60).ceil()),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ChatCapsules?>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final l10n = L10n.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Divider(color: theme.dividerColor),
            ListTile(
              title: Text(
                l10n.chatCapsules,
                style: TextStyle(
                  color: theme.colorScheme.secondary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (data.items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(
                  l10n.chatCapsulesEmpty,
                  style: TextStyle(
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: theme.textTheme.bodyMedium!.color,
                  ),
                ),
              ),
            for (final c in data.items.take(ChatCapsulesSection.maxShown))
              ListTile(
                leading: const Icon(Icons.video_library_outlined),
                title: Text(
                  c.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(_subtitle(context, c)),
                trailing: _actionsMenu(l10n, c),
                onTap: () =>
                    _open(data, '?capsule=${Uri.encodeQueryComponent(c.id)}'),
              ),
            ListTile(
              leading: const Icon(Icons.list_outlined),
              title: Text(l10n.chatCapsulesAll(data.items.length)),
              trailing: const Icon(Icons.chevron_right_outlined),
              onTap: () => _open(data, '?room=1'),
            ),
          ],
        );
      },
    );
  }
}
