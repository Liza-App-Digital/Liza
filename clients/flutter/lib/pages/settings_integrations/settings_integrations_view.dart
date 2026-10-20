import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/settings_integrations/settings_integrations.dart';
import 'package:liza/utils/mcp_connections.dart';
import 'package:liza/utils/xl_credentials.dart';
import 'package:liza/widgets/matrix.dart';

/// Витрина MCP-подключений: «Подключенные» + «Каталог расширений».
class SettingsIntegrationsView extends StatelessWidget {
  const SettingsIntegrationsView(this.controller, {super.key});

  final SettingsIntegrationsController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final client = Matrix.of(context).client;
    final isColumnMode = LizaThemes.isColumnMode(context);

    return Scaffold(
      // В колоночном режиме слева уже список чатов — «назад» уводил бы в
      // пустую правую панель (как settings_security_view.dart).
      appBar: AppBar(
        leading: isColumnMode ? null : const BackButton(),
        automaticallyImplyLeading: !isColumnMode,
        title: Text(l10n.settingsMcpTitle),
      ),
      // Ключ XL живёт в account_data и может смениться НЕ с этого экрана
      // (другое устройство) — за ним следим здесь. Образец —
      // settings_ignore_list_view.dart.
      //
      // ⚠️ Состояние MCP-подключений здесь НЕ слушаем, хотя раньше слушали.
      // Его владелец — контроллер: он спрашивает сервер и делает `setState`
      // сам. Если оставить оба слушателя, на каждое релевантное событие
      // приходит ДВА ребилда, причём первый (от этого StreamBuilder) рисует
      // ещё СТАРЫЕ данные — фетч в тот момент только стартовал. Один писатель
      // числа — одна точка перерисовки.
      //
      // Фильтр обязателен: голый `onSync.stream` эмитит на КАЖДЫЙ цикл синка,
      // и список карточек пересобирался бы десятки раз в минуту просто от
      // чужого трафика. Тот же приём — chat_settings_popup_menu.dart.
      body: StreamBuilder(
        stream: client.onSync.stream.where(_affectsXlKey),
        builder: (context, _) => _body(context),
      ),
    );
  }

  /// Сменился ли ключ XL (единственный источник, который перерисовывает
  /// витрину помимо `setState` контроллера).
  static bool _affectsXlKey(SyncUpdate sync) =>
      sync.accountData?.any((e) => e.type == xlCredentialsAccountDataType) ??
      false;

  Widget _body(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    final connected = mcpCatalog.where(controller.isEnabled).toList();
    final available = mcpCatalog
        .where((s) => !controller.isEnabled(s))
        .toList();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        Text(
          l10n.settingsMcpIntro,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (connected.isNotEmpty) ...[
          _SectionHeader(
            title: l10n.settingsMcpConnectedSection,
            trailing: '${connected.length}',
          ),
          for (final server in connected)
            _McpCard(controller: controller, server: server),
        ],
        _SectionHeader(title: l10n.settingsMcpCatalogSection),
        if (available.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              l10n.settingsMcpAllConnected,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        for (final server in available)
          _McpCard(controller: controller, server: server),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

/// Карточка расширения: плашка-логотип, название, бейдж, описание, действие.
class _McpCard extends StatelessWidget {
  const _McpCard({required this.controller, required this.server});

  final SettingsIntegrationsController controller;
  final McpServer server;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final on = controller.isEnabled(server);
    final busy = controller.pending.contains(server.id);
    final expanded = controller.expandedKeyForm == server.id;
    final detailsOpen = controller.expandedDetailsCard == server.id;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            leading: Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: server.tint,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                server.mark,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            // В title ТОЛЬКО имя. Бейдж уехал в мета-строку ниже: замер на
            // 360dp — title-зона ≈200dp (leading 44 + gap 16 + trailing 48 +
            // паддинги), а имя+бейдж+кнопка = 215dp → имя схлопывалось бы в
            // ellipsis. Владелец просил кнопку «рядом с бейджиком» —
            // соседство сохранено, но в СВОЕЙ строке.
            title: Text(
              server.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.keyUnreadable && server.requiresKey
                      ? l10n.settingsIntegrationsKeyUnreadable
                      : mcpServerDescription(l10n, server.id),
                  style: TextStyle(
                    color: controller.keyUnreadable && server.requiresKey
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _Badge(
                      key: Key('mcpBadge_${server.id}'),
                      text: l10n.settingsMcpFree,
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: Key('mcpDetailsBtn_${server.id}'),
                      onPressed: () => controller.toggleDetails(server),
                      // shrinkWrap обязателен: иначе TextButton тянет
                      // kMinInteractiveDimension 48dp и раздувает строку.
                      style: TextButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(
                        detailsOpen
                            ? l10n.settingsMcpLess
                            : l10n.settingsMcpMore,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            trailing: busy
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    // У ключевых серверов тап РАСКРЫВАЕТ форму ключа, а не
                    // отключает (отключение — отдельная кнопка внутри формы),
                    // поэтому «Отключить» здесь обещало бы не то действие.
                    tooltip: server.requiresKey
                        ? l10n.settingsMcpManage
                        : on
                        ? l10n.settingsMcpDisconnect
                        : l10n.settingsMcpConnect,
                    onPressed: () => controller.toggle(server),
                    icon: Icon(
                      on ? Icons.check_circle : Icons.add_circle_outline,
                      color: on
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
          // Детали идут ПЕРЕД формой ключа: сначала «что это умеет», потом
          // «введи ключ». AnimatedSize — идиома проекта (7 мест), заодно
          // чинит немой скачок формы ключа, который был тут раньше.
          AnimatedSize(
            duration: LizaThemes.animationDuration,
            curve: LizaThemes.animationCurve,
            alignment: Alignment.topCenter,
            child: detailsOpen
                ? _McpDetails(server: server)
                : const SizedBox(width: double.infinity),
          ),
          // Ключевые серверы (XL) подключаются вводом ключа, а не тумблером —
          // у них персональный секрет, и механика уже существует.
          if (expanded && server.requiresKey)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: controller.keyController,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: l10n.settingsIntegrationsXlField,
                      helperText: l10n.settingsIntegrationsXlHint,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: controller.save,
                    child: Text(l10n.settingsIntegrationsSave),
                  ),
                  if (on) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: controller.disconnect,
                      child: Text(l10n.settingsIntegrationsDisconnect),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Раскрытый блок «Подробнее»: абзац, тематики, чего НЕ умеет, примеры команд.
///
/// Примеры рендерятся ТОЛЬКО в русской локали (INV-8). Причина не косметическая:
/// серверный гейт `mcp_intent` — две кириллические регулярки, и переведённая
/// команда через него не проходит («Find milk» и ещё 3 из 4 — мимо). Показать
/// англоязычному пользователю переведённый пример = пообещать неработающее.
class _McpDetails extends StatelessWidget {
  const _McpDetails({required this.server});

  final McpServer server;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final isRu = Localizations.localeOf(context).languageCode == 'ru';
    final about = mcpServerAbout(l10n, server.id);
    final limits = mcpServerLimits(l10n, server.id);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (about != null)
            Text(about, style: theme.textTheme.bodyMedium),
          if (server.topics.isNotEmpty) ...[
            const SizedBox(height: 12),
            _DetailsLabel(text: l10n.settingsMcpTopics),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in server.topics)
                  _Badge(text: mcpTopicTitle(l10n, server.id, t.slug)),
              ],
            ),
          ],
          if (limits != null) ...[
            const SizedBox(height: 10),
            Text(
              limits,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (server.examples.isNotEmpty && isRu) ...[
            const SizedBox(height: 12),
            _DetailsLabel(text: l10n.settingsMcpExamples),
            const SizedBox(height: 6),
            for (final slug in server.examples)
              _ExampleRow(text: mcpExampleText(l10n, server.id, slug)),
          ],
          const SizedBox(height: 10),
          Text(
            server.addressee == McpAddressee.xlBot
                ? l10n.settingsMcpAddresseeXlBot
                : l10n.settingsMcpAddresseeLiza,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailsLabel extends StatelessWidget {
  const _DetailsLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
  );
}

/// Строка примера команды. Тап копирует текст — вставку в композер чата НЕ
/// делаем: `composerPrefill` — ValueNotifier, который не доигрывает значение
/// новым слушателям, а с экрана настроек чат ещё не смонтирован, поэтому
/// префилл терялся бы молча; плюс он затирает черновик пользователя.
class _ExampleRow extends StatelessWidget {
  const _ExampleRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: text));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.settingsMcpExampleCopied)),
          );
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.copy_outlined,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
