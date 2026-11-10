import 'dart:async';

import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/news_poll.dart';
import 'package:liza/widgets/avatar.dart';

enum _LoadState { loading, data, forbidden, error }

/// «Результаты опроса» Liza News, как в популярных мессенджерах: по каждому варианту — число
/// голосов и кто голосовал. Итоги отдаёт бот и только разработчикам из списка
/// редакции; эта страница — лишь витрина его ответа.
class NewsPollResultsPage extends StatefulWidget {
  final Room room;
  final String botMxid;
  final NewsPollData poll;

  /// Подмена загрузки в тестах (реальный путь — to-device боту).
  final Future<NewsPollResults> Function()? loader;

  const NewsPollResultsPage({
    required this.room,
    required this.botMxid,
    required this.poll,
    this.loader,
    super.key,
  });

  static Future<void> open(
    BuildContext context, {
    required Room room,
    required String botMxid,
    required NewsPollData poll,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          NewsPollResultsPage(room: room, botMxid: botMxid, poll: poll),
    ),
  );

  @override
  State<NewsPollResultsPage> createState() => _NewsPollResultsPageState();
}

class _NewsPollResultsPageState extends State<NewsPollResultsPage> {
  _LoadState _state = _LoadState.loading;
  NewsPollResults? _results;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = _LoadState.loading);
    try {
      final results =
          await (widget.loader?.call() ??
              NewsPollService.of(
                widget.room.client,
              ).requestResults(widget.botMxid, widget.poll));
      if (!mounted) return;
      setState(() {
        _results = results;
        _state = _LoadState.data;
      });
    } on NewsPollForbidden {
      if (mounted) setState(() => _state = _LoadState.forbidden);
    } catch (e) {
      Logs().w('[NewsPoll] results: $e');
      if (mounted) setState(() => _state = _LoadState.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.newsPollResultsTitle),
        actions: [
          IconButton(
            tooltip: l10n.newsPollRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: _state == _LoadState.loading ? null : _load,
          ),
        ],
      ),
      body: switch (_state) {
        _LoadState.loading => const Center(
          child: CircularProgressIndicator.adaptive(),
        ),
        _LoadState.forbidden => _message(l10n.newsPollResultsForbidden),
        _LoadState.error => _message(
          l10n.newsPollResultsFailed,
          action: TextButton(onPressed: _load, child: Text(l10n.tryAgain)),
        ),
        _LoadState.data => _buildResults(context, _results!),
      },
    );
  }

  Widget _message(String text, {Widget? action}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          if (action != null) action,
        ],
      ),
    ),
  );

  Widget _buildResults(BuildContext context, NewsPollResults results) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(widget.poll.question, style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            [
              l10n.newsPollTotalVoters(results.totalVoters),
              if (results.closed) l10n.newsPollClosed,
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (newsAudienceLabel(results.audience) case final audience?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l10n.newsPollAudience(audience),
              key: const ValueKey('news-poll-audience'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (results.totalVoters == 0)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(l10n.newsPollNoVotes)),
          ),
        for (final option in results.options) ...[
          const Divider(),
          ListTile(
            title: Text(option.text, style: theme.textTheme.titleSmall),
            trailing: Text(l10n.newsPollOptionVotes(option.voters.length)),
          ),
          for (final mxid in option.voters)
            _VoterTile(room: widget.room, mxid: mxid),
        ],
      ],
    );
  }
}

class _VoterTile extends StatelessWidget {
  final Room room;
  final String mxid;
  const _VoterTile({required this.room, required this.mxid});

  @override
  Widget build(BuildContext context) {
    final user = room.unsafeGetUserFromMemoryOrFallback(mxid);
    final name = user.calcDisplayname();
    return ListTile(
      dense: true,
      leading: Avatar(mxContent: user.avatarUrl, name: name, size: 32),
      title: Text(name),
      subtitle: Text(mxid),
    );
  }
}
