import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_registry.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/utils/date_time_extension.dart';

/// Капсула созвона, привязанная к чату (ответ `GET /liza/chat-capsules`).
class ChatCapsule {
  final String id;
  final String title;
  final DateTime? startedAt;
  final int? durationSec;

  const ChatCapsule({
    required this.id,
    required this.title,
    this.startedAt,
    this.durationSec,
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
    items.add(
      ChatCapsule(
        id: id,
        title: title is String && title.isNotEmpty ? title : id,
        startedAt: started is String ? DateTime.tryParse(started) : null,
        durationSec: duration is num ? duration.toInt() : null,
      ),
    );
  }
  return ChatCapsules(appId, items);
}

typedef ChatCapsulesLoader = Future<ChatCapsules?> Function(Room room);

Future<ChatCapsules?> loadChatCapsules(Room room) async {
  final client = room.client;
  final host = client.homeserver?.host;
  final token = client.accessToken;
  if (host == null || host.isEmpty || token == null) return null;
  final base = AppConfig.lizaBotApiBaseForHomeserver(host);
  final url = Uri.parse(
    '$base/liza/chat-capsules',
  ).replace(queryParameters: {'room_id': room.id});
  try {
    final resp = await http
        .get(
          url,
          headers: {
            'Authorization': 'Bearer $token',
            if (client.homeserver != null)
              'X-Liza-Homeserver': client.homeserver!.toString(),
          },
        )
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(utf8.decode(resp.bodyBytes));
    return data is Map<String, dynamic> ? parseChatCapsules(data) : null;
  } catch (e) {
    Logs().w('[ChatCapsules] load failed: $e');
    return null;
  }
}

/// Раздел «Капсулы созвонов» в деталях чата: капсулы, привязанные к чату, открываются
/// в мини-аппе капсул (`?capsule=<id>`), «Все капсулы чата» — его список (`?room=1`).
class ChatCapsulesSection extends StatefulWidget {
  final Room room;
  final ChatCapsulesLoader loader;

  const ChatCapsulesSection({
    required this.room,
    this.loader = loadChatCapsules,
    super.key,
  });

  static const int maxShown = 5;

  @override
  State<ChatCapsulesSection> createState() => _ChatCapsulesSectionState();
}

class _ChatCapsulesSectionState extends State<ChatCapsulesSection> {
  late final Future<ChatCapsules?> _future = widget.loader(widget.room);

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
