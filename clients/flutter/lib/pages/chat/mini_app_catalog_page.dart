import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_registry.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/widgets/developer_mark.dart';
import 'package:liza/widgets/matrix.dart';

enum _CatalogState { loading, data, empty, error }

/// Каталог listed-приложений miniApp.
///
/// Тап по карточке запускает app напрямую через [MiniAppWebView.open] —
/// без Matrix-события и без бота. Опорная комната (требуется конструктором
/// overlay) берётся из первой комнаты пользователя; room_id в init_data
/// опционален, поэтому для каталожного запуска этого достаточно.
class MiniAppCatalogPage extends StatefulWidget {
  const MiniAppCatalogPage({super.key});

  @override
  State<MiniAppCatalogPage> createState() => _MiniAppCatalogPageState();
}

class _MiniAppCatalogPageState extends State<MiniAppCatalogPage> {
  _CatalogState _state = _CatalogState.loading;
  List<CatalogApp> _apps = const [];
  String? _error;

  Client get _client => Matrix.of(context).client;

  @override
  void initState() {
    super.initState();
    // Загрузка реестра один раз через кэш (не в build).
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    if (mounted && !force) {
      setState(() => _state = _CatalogState.loading);
    }
    try {
      final apps = await MiniAppRegistry.instance.fetch(_client, force: force);
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _state = apps.isEmpty ? _CatalogState.empty : _CatalogState.data;
      });
    } catch (e) {
      Logs().w('[MiniAppCatalog] не удалось загрузить реестр: $e');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _state = _CatalogState.error;
      });
    }
  }

  /// Опорная комната для запуска приложения вне чата.
  /// Берём первую не-space комнату; если комнат нет — null.
  Room? _anchorRoom() {
    for (final room in _client.rooms) {
      if (!room.isSpace) return room;
    }
    return null;
  }

  void _openApp(CatalogApp app) {
    final room = _anchorRoom();
    if (room == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).miniAppCatalogOpenChatToLaunch),
        ),
      );
      return;
    }
    MiniAppWebView.open(
      context: context,
      appUrl: app.url,
      appId: app.appId,
      appName: app.name,
      room: room,
      appType: app.type,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.of(context).miniAppCatalogTitle)),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _CatalogState.loading:
        return const Center(child: CircularProgressIndicator());
      case _CatalogState.error:
        return _buildError();
      case _CatalogState.empty:
        return _buildEmpty();
      case _CatalogState.data:
        return ListView.builder(
          itemCount: _apps.length,
          itemBuilder: (context, i) => _buildTile(_apps[i]),
        );
    }
  }

  Widget _buildTile(CatalogApp app) {
    final isFirstParty = app.type == 'first_party';
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: SizedBox(
        width: 40,
        height: 40,
        child: app.icon.isEmpty
            ? const Icon(Icons.apps)
            : Image.network(
                app.icon,
                width: 40,
                height: 40,
                errorBuilder: (context, error, stack) => const Icon(Icons.apps),
              ),
      ),
      title: Text(app.name),
      subtitle: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: isFirstParty
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              isFirstParty
                  ? L10n.of(context).miniAppCatalogFirstParty
                  : L10n.of(context).miniAppCatalogThirdParty,
              style: TextStyle(
                fontSize: 11,
                color: isFirstParty
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (app.shortDescription != null &&
              app.shortDescription!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                app.shortDescription!,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
      onTap: () => _openApp(app),
    );
  }

  Widget _buildEmpty() {
    final isDeveloper = Matrix.of(context).isCurrentUserDeveloper;
    // ListView нужен, чтобы RefreshIndicator работал даже при пустом каталоге.
    return ListView(
      children: [
        const SizedBox(height: 96),
        const Center(child: Icon(Icons.apps, size: 64)),
        const SizedBox(height: 16),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              L10n.of(context).miniAppCatalogEmpty,
              textAlign: TextAlign.center,
            ),
          ),
        ),
        if (isDeveloper) ...[
          const SizedBox(height: 24),
          Center(
            child: FilledButton.icon(
              icon: const Icon(Icons.add),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(L10n.of(context).miniAppCatalogConnectOwn),
                  const SizedBox(width: 6),
                  const DeveloperMark(),
                ],
              ),
              onPressed: _openDeveloperPortal,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildError() {
    return ListView(
      children: [
        const SizedBox(height: 96),
        Center(
          child: Icon(
            Icons.error_outline,
            size: 64,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              L10n.of(context).miniAppCatalogLoadFailed(_error ?? ''),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: FilledButton(
            onPressed: () => _load(force: true),
            child: Text(L10n.of(context).retry),
          ),
        ),
      ],
    );
  }

  void _openDeveloperPortal() {
    final room = _anchorRoom();
    if (room == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).miniAppCatalogOpenChatToCabinet),
        ),
      );
      return;
    }
    MiniAppWebView.open(
      context: context,
      appUrl: AppConfig.developerPortalUrl,
      appId: 'liza-dev-portal',
      appName: L10n.of(context).miniAppDeveloperCabinet,
      room: room,
      appType: 'first_party',
    );
  }
}
