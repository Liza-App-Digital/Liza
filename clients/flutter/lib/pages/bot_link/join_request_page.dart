import 'dart:async';

import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/utils/wait_for_room_in_sync.dart';
import 'package:liza/widgets/matrix.dart';

/// Заявитель ещё не участник: сведения о проверке приходят приватным HTTP.
class JoinRequestPage extends StatefulWidget {
  final String roomId;
  final BotInteractiveApi Function(Client)? apiFactory;
  final Future<void> Function(Client, String)? joinRoom;
  final Future<bool> Function(Client, String)? awaitJoined;
  const JoinRequestPage({
    super.key,
    required this.roomId,
    this.apiFactory,
    this.joinRoom,
    this.awaitJoined,
  });

  @override
  State<JoinRequestPage> createState() => _JoinRequestPageState();
}

class _JoinRequestPageState extends State<JoinRequestPage> {
  BotInteractiveApi? _api;
  Timer? _poll;
  var _generation = 0;
  bool _loading = false;
  bool _acting = false;
  bool _failed = false;
  String? _outcome;
  List<Map<String, dynamic>> _queries = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = Matrix.of(context).client;
    if (!identical(_api?.client, client)) {
      _api?.dispose();
      _api = widget.apiFactory?.call(client) ?? BotInteractiveApi(client);
      _reset();
    }
  }

  @override
  void didUpdateWidget(covariant JoinRequestPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomId != widget.roomId) _reset();
  }

  void _reset() {
    _generation++;
    _queries = [];
    _outcome = null;
    _poll?.cancel();
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final api = _api;
    if (api == null || !api.isCurrent || _loading) return;
    final generation = _generation;
    _loading = true;
    try {
      final result = await api.request(
        'GET',
        '/liza/interactive/join',
        query: {'room_id': widget.roomId},
      );
      if (!mounted || generation != _generation || !api.isCurrent) return;
      final rows = result['queries'];
      setState(() {
        final items = rows is List
            ? rows.whereType<Map<String, dynamic>>().toList()
            : <Map<String, dynamic>>[];
        _queries = items
            .where(
              (row) => row['status'] == 'answered' && row['web_app'] is Map,
            )
            .toList();
        _outcome = items
            .where(
              (row) => row['status'] == 'consumed' && row['outcome'] is String,
            )
            .map((row) => row['outcome'] as String)
            .firstOrNull;
        if (items.any(
          (row) => row['status'] == 'pending' || row['status'] == 'answered',
        )) {
          _outcome = null;
        }
      });
    } catch (e) {
      // Ожидание заявки остаётся рабочим, даже если бот-проверка недоступна.
      Logs().w('[JoinRequest] query refresh: ${e.runtimeType}');
    } finally {
      _loading = false;
    }
  }

  Future<void> _open(Map<String, dynamic> query) async {
    final api = _api;
    if (api == null || !api.isCurrent || _acting) return;
    final generation = _generation;
    final route = ModalRoute.of(context);
    bool current() =>
        mounted &&
        generation == _generation &&
        api.isCurrent &&
        (route?.isCurrent ?? true);
    setState(() {
      _acting = true;
      _failed = false;
    });
    try {
      final app = query['web_app'] as Map;
      final mxid = query['bot_mxid'] ?? app['bot_mxid'];
      final id = query['query_id'];
      final url = app['url'];
      if (mxid is! String || id is! String || url is! String) {
        throw const FormatException();
      }
      final bot = await api.resolve(mxid: mxid);
      final launch = bot?.appForUrl(url);
      if (launch == null || !current()) throw StateError('App unavailable');
      final roomId = await api.client.ensureDirectChat(mxid);
      final room = api.client.getRoomById(roomId);
      if (room == null || !current()) throw StateError('Room unavailable');
      await MiniAppWebView.open(
        context: context,
        appUrl: launch.appUrl,
        appId: launch.appId,
        appName: launch.appName,
        appType: launch.appType,
        room: room,
        botMxid: mxid,
        joinRequestQueryId: id,
      );
    } catch (e) {
      Logs().w('[JoinRequest] open failed: ${e.runtimeType}');
      if (current()) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation && api.isCurrent) {
        setState(() => _acting = false);
      }
    }
  }

  Future<void> _join() async {
    final api = _api;
    if (api == null || !api.isCurrent || _acting) return;
    final generation = _generation;
    final route = ModalRoute.of(context);
    setState(() {
      _acting = true;
      _failed = false;
    });
    try {
      if (widget.joinRoom != null) {
        await widget.joinRoom!(api.client, widget.roomId);
      } else {
        await api.client.joinRoom(widget.roomId);
      }
      if (!mounted ||
          generation != _generation ||
          !api.isCurrent ||
          !(route?.isCurrent ?? true)) {
        return;
      }
      final arrived =
          await (widget.awaitJoined?.call(api.client, widget.roomId) ??
              waitForRoomInSync(api.client, widget.roomId, expectSpace: false));
      if (arrived) {
        if (mounted &&
            generation == _generation &&
            api.isCurrent &&
            (route?.isCurrent ?? true)) {
          context.go('/rooms/${Uri.encodeComponent(widget.roomId)}');
        }
      } else {
        throw StateError('Room unavailable');
      }
    } catch (e) {
      if (mounted && generation == _generation && api.isCurrent) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted && generation == _generation && api.isCurrent) {
        setState(() => _acting = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _poll?.cancel();
    _api?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.botJoinRequestTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.hourglass_top, size: 48),
              const SizedBox(height: 16),
              Text(
                _outcome == 'decline'
                    ? l10n.botJoinRequestDeclined
                    : l10n.botJoinRequestWaiting,
                textAlign: TextAlign.center,
              ),
              for (final query in _queries)
                FilledButton(
                  onPressed: _acting ? null : () => _open(query),
                  child: Text(l10n.botJoinRequestCheck),
                ),
              if (_outcome == 'approve' ||
                  _api?.client.getRoomById(widget.roomId)?.membership ==
                      Membership.invite ||
                  _api?.client.getRoomById(widget.roomId)?.membership ==
                      Membership.join)
                FilledButton(
                  onPressed: _acting ? null : _join,
                  child: Text(l10n.botJoinRequestJoin),
                ),
              if (_failed) Text(l10n.botStartFailed),
            ],
          ),
        ),
      ),
    );
  }
}
