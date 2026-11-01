import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/utils/bot_deep_link.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/bot_link_membership.dart';
import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/widgets/matrix.dart';

/// Ссылка показывает намерение; ни DM, ни /start не создаются до нажатия.
class BotLinkPage extends StatefulWidget {
  final BotDeepLink link;
  final BotInteractiveApi Function(Client)? apiFactory;
  const BotLinkPage({super.key, required this.link, this.apiFactory});

  @override
  State<BotLinkPage> createState() => _BotLinkPageState();
}

class _BotLinkPageState extends State<BotLinkPage> {
  Client? _client;
  BotInteractiveApi? _api;
  Future<RegisteredBot?>? _lookup;
  bool _sending = false;
  bool _failed = false;
  var _generation = 0;
  String _txid = '';

  void _load(Client client) {
    _api?.dispose();
    _client = client;
    _api = widget.apiFactory?.call(client) ?? BotInteractiveApi(client);
    _lookup = _api!.resolve(username: widget.link.username);
    _txid = 'bot-start-${DateTime.now().microsecondsSinceEpoch}';
    _generation++;
    _sending = false;
    _failed = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = Matrix.of(context).client;
    if (!identical(client, _client)) _load(client);
  }

  @override
  void didUpdateWidget(covariant BotLinkPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link.route != widget.link.route && _client != null) {
      _load(_client!);
    }
  }

  @override
  void dispose() {
    _generation++;
    _api?.dispose();
    super.dispose();
  }

  Future<void> _start(RegisteredBot bot) async {
    if (_sending || _client == null || _api?.isCurrent != true) return;
    final generation = _generation;
    final client = _client!;
    final api = _api!;
    final route = ModalRoute.of(context);
    bool current() =>
        mounted &&
        generation == _generation &&
        api.isCurrent &&
        (route?.isCurrent ?? true);
    setState(() {
      _sending = true;
      _failed = false;
    });
    try {
      // После долгого диалога/переключения аккаунта запись бота могла измениться.
      final fresh = await api.resolve(username: widget.link.username);
      if (!current() || fresh == null || fresh.mxid != bot.mxid) {
        throw StateError('Bot changed');
      }
      final roomId = await client.ensureDirectChat(bot.mxid);
      if (!current()) return;
      final room = client.getRoomById(roomId);
      if (room == null) throw StateError('Room unavailable');
      if (widget.link.opensApp) {
        final apps = fresh.data['miniapps'];
        if (apps is! List || apps.isEmpty || apps.first is! Map) {
          throw StateError('App unavailable');
        }
        final app = apps.first as Map;
        final url = app['url'];
        final id = app['app_id'];
        if (url is! String || id is! String || fresh.appForUrl(url) == null) {
          throw StateError('App unavailable');
        }
        if (!current()) return;
        context.go('/rooms/${Uri.encodeComponent(roomId)}');
        await MiniAppWebView.open(
          context: context,
          appUrl: url,
          appId: id,
          appName: app['name'] as String? ?? widget.link.username,
          room: room,
          appType: app['app_type'] as String? ?? 'third_party',
          startParam: widget.link.parameter,
        );
      } else {
        if (!await waitForBotLinkMembership(
              client,
              roomId,
              bot.mxid,
              isCurrent: current,
            ) ||
            !current()) {
          throw StateError('Bot unavailable');
        }
        final text = widget.link.parameter.isEmpty
            ? '/start'
            : '/start ${widget.link.parameter}';
        final id = await room.sendTextEvent(
          text,
          parseCommands: false,
          parseMarkdown: false,
          txid: _txid,
        );
        if (id == null) throw StateError('Send failed');
        if (current()) context.go('/rooms/${Uri.encodeComponent(roomId)}');
      }
    } catch (e) {
      Logs().w('[BotLink] start failed: ${e.runtimeType}');
      if (current()) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation && api.isCurrent) {
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.botStartTitle)),
      body: Center(
        child: FutureBuilder<RegisteredBot?>(
          future: _lookup,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const CircularProgressIndicator();
            }
            final bot = snapshot.data;
            if (bot == null) return Text(l10n.botUnavailable);
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bot.data['name'] as String? ?? widget.link.username,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (widget.link.parameter.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(l10n.botStartPayload(widget.link.parameter)),
                    ),
                  if (_failed) Text(l10n.botStartFailed),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _sending ? null : () => _start(bot),
                    child: _sending
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(),
                          )
                        : Text(
                            widget.link.opensApp
                                ? l10n.botStartApp
                                : l10n.botStartButton,
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
