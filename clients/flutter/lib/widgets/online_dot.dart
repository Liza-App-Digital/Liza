import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Единая точка «в сети»: тот же зелёный, что у плашки роли «ИИ»
/// (`#4CAF50`, `UserRoleBadge._defaultBg` и каталог ролей Synapse), чтобы в
/// интерфейсе не было разноцветия (Надежда, 05.11).
class OnlineDot extends StatelessWidget {
  const OnlineDot({super.key, this.size = 12});

  static const Color color = Color(0xFF4CAF50);

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(
        color: Theme.of(context).colorScheme.surface,
        width: 2,
      ),
    ),
  );
}

/// Рисует [OnlineDot] только пока [userId] онлайн. Без сети: стартовое
/// значение — из кэша `client.presences`, дальше — `onPresenceChanged`
/// (в отличие от `PresenceBuilder`, который делает fetchCurrentPresence на
/// каждый виджет — для списка чатов это запрос на строку).
class OnlinePresenceDot extends StatefulWidget {
  const OnlinePresenceDot({
    super.key,
    required this.client,
    required this.userId,
    this.size = 12,
  });

  final Client client;
  final String userId;
  final double size;

  @override
  State<OnlinePresenceDot> createState() => _OnlinePresenceDotState();
}

class _OnlinePresenceDotState extends State<OnlinePresenceDot> {
  late bool _online;
  StreamSubscription<CachedPresence>? _sub;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(OnlinePresenceDot old) {
    super.didUpdateWidget(old);
    if (old.userId != widget.userId || old.client != widget.client) {
      _sub?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    final userId = widget.userId;
    // ignore: deprecated_member_use
    final cached = widget.client.presences[userId];
    _online = cached?.presence == PresenceType.online;
    var live = false;
    _sub = widget.client.onPresenceChanged.stream
        .where((p) => p.userid == userId)
        .listen((p) {
          live = true;
          _apply(p.presence == PresenceType.online);
        });
    if (cached != null) return;
    // SDK чистит память presences на init(), а инкрементальный sync после
    // перезапуска приносит только СМЕНЫ статуса — собеседник, онлайн ещё до
    // рестарта, остался бы без точки. Сохранённое значение лежит в БД SDK;
    // fetchOnlyFromCached — без сетевого запроса на строку.
    widget.client.fetchCurrentPresence(userId, fetchOnlyFromCached: true).then((
      p,
    ) {
      if (live || userId != widget.userId) return;
      _apply(p.presence == PresenceType.online);
    }, onError: (_) {});
  }

  void _apply(bool online) {
    if (!mounted || online == _online) return;
    setState(() => _online = online);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _online
      ? OnlineDot(
          key: ValueKey('chatListOnlineDot:${widget.userId}'),
          size: widget.size,
        )
      : const SizedBox.shrink();
}
