import 'dart:async';

import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/bot_interactive_draft.dart';
import 'package:liza/utils/bot_interactive_consent.dart';
import 'package:liza/utils/miniapp_room.dart';

/// Меню доступно собеседнику бота. В группе сначала выбирается конкретный бот;
/// effective commands сервер вычисляет по room/user scope.
class InteractiveBotMenu extends StatefulWidget {
  final Room room;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final Future<void> Function(MiniAppLaunch) onOpenApp;
  const InteractiveBotMenu({
    required this.room,
    required this.controller,
    required this.onChanged,
    required this.onOpenApp,
    super.key,
  });
  @override
  State<InteractiveBotMenu> createState() => _InteractiveBotMenuState();
}

class _InteractiveBotMenuState extends State<InteractiveBotMenu>
    with WidgetsBindingObserver {
  late BotInteractiveApi _api;
  List<RegisteredBot> _bots = const [];
  bool _busy = false;
  int _generation = 0;
  String _members = '';
  StreamSubscription? _sync;
  Timer? _retry;
  Timer? _refresh;
  String _membershipSignature() {
    final members =
        widget.room.states[EventTypes.RoomMember]?.values
            .map((event) => '${event.stateKey}:${event.content['membership']}')
            .toList() ??
        <String>[];
    members.sort();
    return members.join('|');
  }

  void _attach() {
    _api = BotInteractiveApi(widget.room.client);
    _members = _membershipSignature();
    _sync = widget.room.client.onSync.stream.listen((_) => _checkMembers());
    _load();
  }

  void _checkMembers() {
    final signature = _membershipSignature();
    if (signature == _members) return;
    _members = signature;
    _refresh?.cancel();
    // Один запрос для пачки membership-событий sync.
    _refresh = Timer(const Duration(milliseconds: 200), _load);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach();
  }

  @override
  void didUpdateWidget(InteractiveBotMenu old) {
    super.didUpdateWidget(old);
    if (old.room != widget.room || !_api.isCurrent) {
      _sync?.cancel();
      _retry?.cancel();
      _refresh?.cancel();
      _api.dispose();
      _bots = const [];
      _attach();
    } else {
      _checkMembers();
    }
  }

  Future<void> _load() async {
    _retry?.cancel();
    final generation = ++_generation;
    final api = _api;
    try {
      final response = await api.request(
        'GET',
        '/liza/bots/room',
        query: {'room_id': widget.room.id},
      );
      if (!mounted || generation != _generation || !api.isCurrent) return;
      final raw = response['bots'];
      setState(
        () => _bots = raw is List
            ? [
                for (final item in raw)
                  if (item is Map<String, dynamic> &&
                      RegisteredBot.parse(item) != null)
                    RegisteredBot.parse(item)!,
              ]
            : [],
      );
    } catch (_) {
      if (!mounted || generation != _generation || !api.isCurrent) return;
      _retry = Timer(const Duration(seconds: 5), () {
        if (WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed ||
            WidgetsBinding.instance.lifecycleState == null) {
          _load();
        }
      });
    }
  }

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    final generation = _generation;
    bool current() => mounted && generation == _generation && _api.isCurrent;
    try {
      final bot = _bots.length == 1
          ? _bots.single
          : await showInteractiveConsent<RegisteredBot>(
              context: context,
              isCurrent: current,
              builder: (context) => SimpleDialog(
                title: Text(L10n.of(context).botChooseBot),
                children: [
                  for (final bot in _bots)
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(context).pop(bot),
                      child: Text(bot.mxid),
                    ),
                ],
              ),
            );
      if (bot == null || !current()) return;
      final response = await _api.request(
        'GET',
        '/liza/bots/menu',
        query: {'mxid': bot.mxid, 'room_id': widget.room.id},
      );
      if (!current()) return;
      final button = response['menu_button'];
      if (button is Map && button['type'] == 'web_app') {
        final webApp = button['web_app'];
        final fresh = await _api.resolve(mxid: bot.mxid, force: true);
        if (!current() || webApp is! Map || webApp['url'] is! String) return;
        final launch = fresh?.appForUrl(webApp['url'] as String);
        if (launch == null) throw StateError('App not registered');
        await widget.onOpenApp(launch);
        return;
      }
      final commands = response['commands'];
      if (commands is! List) return;
      final command = await showInteractiveConsent<String>(
        context: context,
        isCurrent: current,
        builder: (context) => SimpleDialog(
          title: Text(L10n.of(context).botCommandsMenu),
          children: [
            for (final c in commands)
              if (c is Map &&
                  c['command'] is String &&
                  RegExp(r'^[a-z0-9_]{1,32}$').hasMatch(c['command'] as String))
                SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(c['command']),
                  child: ListTile(
                    title: Text('/${c['command']}'),
                    subtitle: Text(
                      c['description'] is String
                          ? c['description'] as String
                          : '',
                    ),
                  ),
                ),
          ],
        ),
      );
      if (!current() || command == null) return;
      final suffix = widget.room.directChatMatrixID == bot.mxid
          ? ''
          : '@${bot.mxid.localpart}';
      final text = '/$command$suffix ';
      BotInteractiveDraft.markCommand(
        widget.room.client,
        widget.room.id,
        text.trim(),
      );
      widget.controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      widget.onChanged(text);
    } catch (_) {
      if (current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).botInteractiveFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    _sync?.cancel();
    _refresh?.cancel();
    _retry?.cancel();
    _api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _bots.isEmpty
      ? const SizedBox.shrink()
      : IconButton(
          tooltip: L10n.of(context).botCommandsMenu,
          onPressed: _busy ? null : _open,
          icon: const Icon(Icons.menu),
        );
}
