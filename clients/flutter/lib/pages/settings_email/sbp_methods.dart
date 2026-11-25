import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher_string.dart';

import 'package:liza/l10n/l10n.dart';

/// Привязанный счёт СБП, как его отдаёт auth-proxy.
///
/// Полного номера телефона/счёта здесь нет и быть не должно: только маска.
class SbpMethod {
  const SbpMethod({
    required this.bindingId,
    required this.state,
    this.bank,
    this.mask,
    this.chargeable = false,
  });

  final String bindingId;
  final String state;
  final String? bank;
  final String? mask;
  final bool chargeable;

  bool get isPending => state == 'pending';
  bool get isRevoked => state == 'revoked';

  factory SbpMethod.fromJson(Map<String, dynamic> json) => SbpMethod(
        bindingId: (json['binding_id'] ?? '').toString(),
        state: (json['state'] ?? '').toString(),
        bank: json['bank'] as String?,
        mask: json['mask'] as String?,
        chargeable: json['chargeable'] == true,
      );
}

/// Ошибка платёжного API с машинным кодом (текст человеку даёт L10n).
class SbpMethodsException implements Exception {
  const SbpMethodsException(this.code);

  final String code;

  @override
  String toString() => 'SbpMethodsException($code)';
}

/// Клиент методов оплаты кабинета.
///
/// Ходит в auth-proxy (не в платёжный сервис): тот проверяет Matrix-токен и
/// сам пересылает запрос на сервер. Поэтому здесь только Bearer и server_name,
/// ровно как у привязки почты.
class SbpMethodsApi {
  SbpMethodsApi({
    required this.baseUrl,
    required this.token,
    required this.serverName,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final String serverName;
  final http.Client _client;

  void close() => _client.close();

  Uri _uri(String suffix, [Map<String, String>? query]) => Uri.https(
        baseUrl,
        '/api/account/payment-methods$suffix',
        query,
      );

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  Future<List<SbpMethod>> list({bool refresh = false}) async {
    final uri = _uri('', {
      'server_name': serverName,
      if (refresh) 'refresh': '1',
    });
    final response = await _client.get(uri, headers: _headers);
    final body = _decode(response);
    if (response.statusCode == 404) {
      // Модуль платежей выключен на сервере — раздел не показываем вовсе.
      throw const SbpMethodsException('payments_disabled');
    }
    if (response.statusCode != 200) throw _error(body);
    final methods = body['methods'];
    return [
      for (final item in (methods is List ? methods : const []))
        if (item is Map<String, dynamic>) SbpMethod.fromJson(item),
    ];
  }

  Future<SbpAttachResult> attach(String attachKey) async {
    final response = await _client.post(
      _uri(''),
      headers: _headers,
      body: jsonEncode({'server_name': serverName, 'attach_key': attachKey}),
    );
    final body = _decode(response);
    if (response.statusCode != 200) throw _error(body);
    final raw = body['method'];
    final method = raw is Map<String, dynamic>
        ? SbpMethod.fromJson(raw)
        : null;
    final link = raw is Map<String, dynamic>
        ? ((raw['link_payload'] as String?) ?? (raw['link_deep_link'] as String?))
        : null;
    return SbpAttachResult(method, link);
  }

  Future<void> detach(String bindingId) async {
    final response = await _client.post(
      _uri('/detach'),
      headers: _headers,
      body: jsonEncode({'server_name': serverName, 'binding_id': bindingId}),
    );
    final body = _decode(response);
    if (response.statusCode != 200) throw _error(body);
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.body.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  SbpMethodsException _error(Map<String, dynamic> body) =>
      SbpMethodsException((body['error'] ?? 'network_error').toString());
}

/// Ответ привязки: созданный метод и ссылка в банк (пока pending).
class SbpAttachResult {
  const SbpAttachResult(this.method, this.link);

  final SbpMethod? method;
  final String? link;
}

/// Раздел «Счета СБП» на экране «Ваш ID»: список, привязка, отзыв.
///
/// Список тот же, что видит бот: один реестр на кабинет. Привязка открывает
/// ссылку в банке, после возврата в приложение состояние обновляется — счёт
/// считается привязанным только когда банк подтвердил (active).
class SbpMethodsSection extends StatefulWidget {
  const SbpMethodsSection({
    required this.baseUrl,
    required this.token,
    required this.serverName,
    this.api,
    this.openLink,
    super.key,
  });

  final String baseUrl;
  final String token;
  final String serverName;

  /// Подменяется в тестах; в приложении создаётся сам (и сам закрывается).
  final SbpMethodsApi? api;

  /// Открытие банковской ссылки; подменяется в тестах.
  final Future<bool> Function(String url)? openLink;

  @override
  State<SbpMethodsSection> createState() => _SbpMethodsSectionState();
}

class _SbpMethodsSectionState extends State<SbpMethodsSection>
    with WidgetsBindingObserver {
  late final SbpMethodsApi _api = widget.api ??
      SbpMethodsApi(
        baseUrl: widget.baseUrl,
        token: widget.token,
        serverName: widget.serverName,
      );
  late final bool _ownsApi = widget.api == null;

  List<SbpMethod> _methods = const [];
  String? _error;
  String? _pendingBinding;
  bool _loading = false;
  // Ключ привязки на попытку: повтор после потерянного ответа возвращает ту же
  // привязку, а не создаёт вторую pending (та же логика, что у бота).
  String? _attachKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsApi) _api.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Вернулись из банка — читаем фактическое состояние привязки.
    if (state == AppLifecycleState.resumed && _pendingBinding != null) {
      _load(refresh: true);
    }
  }

  Future<void> _load({bool refresh = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final methods = await _api.list(refresh: refresh);
      if (!mounted) return;
      setState(() {
        _methods = methods;
        _pendingBinding = methods
            .where((m) => m.isPending)
            .map((m) => m.bindingId)
            .fold<String?>(null, (_, id) => id);
        if (_pendingBinding == null) _attachKey = null;
        _loading = false;
      });
    } on SbpMethodsException catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err.code;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'network_error';
        _loading = false;
      });
    }
  }

  String _newAttachKey() {
    final random = Random.secure();
    final tail = List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}$tail';
  }

  Future<void> _attach() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final key = _attachKey ??= _newAttachKey();
      final result = await _api.attach(key);
      if (!mounted) return;
      final pending = result.method;
      if (pending != null) {
        setState(() => _pendingBinding = pending.bindingId);
      }
      final link = result.link;
      var opened = true;
      if (link != null && link.isNotEmpty) {
        final opener = widget.openLink ?? _openExternally;
        opened = await opener(link);
      }
      await _load(refresh: true);
      // Ошибку открытия ставим ПОСЛЕ перезагрузки: _load обнуляет _error.
      if (!opened && mounted) {
        setState(() => _error = 'link_failed');
      }
    } on SbpMethodsException catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err.code;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'network_error';
        _loading = false;
      });
    }
  }

  Future<bool> _openExternally(String url) async {
    try {
      return await launchUrlString(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  Future<void> _check() async {
    final binding = _pendingBinding;
    if (binding == null) {
      await _load(refresh: true);
      return;
    }
    await _load(refresh: true);
  }

  Future<void> _detach(SbpMethod method) async {
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.settingsSbpDetach),
        content: Text(l10n.settingsSbpDetachConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.settingsSbpDetach),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.detach(method.bindingId);
    } on SbpMethodsException catch (err) {
      if (mounted) setState(() => _error = err.code);
      return;
    }
    await _load(refresh: true);
  }

  String _stateLabel(L10n l10n, SbpMethod method) {
    if (method.chargeable) return l10n.settingsSbpActive;
    return switch (method.state) {
      'pending' => l10n.settingsSbpPending,
      'revoked' => l10n.settingsSbpRevoked,
      'expired' => l10n.settingsSbpExpired,
      _ => l10n.settingsSbpPending,
    };
  }

  String _errorText(L10n l10n, String code) => switch (code) {
        'no_contact' => l10n.settingsSbpNoContact,
        'bindings_limit' => l10n.settingsSbpLimit,
        'payments_unavailable' => l10n.settingsSbpUnavailable,
        'link_failed' => l10n.settingsSbpLinkFailed,
        _ => l10n.settingsSbpError,
      };

  @override
  Widget build(BuildContext context) {
    if (_error == 'payments_disabled') {
      // Серверный выключатель: фичи нет — не показываем ни заголовка, ни ошибки.
      return const SizedBox.shrink();
    }
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.settingsSbpTitle,
                style: theme.textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: _loading ? null : _attach,
              icon: const Icon(Icons.add_card_outlined, size: 18),
              label: Text(l10n.settingsSbpAttach),
            ),
          ],
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_methods.isEmpty && !_loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              l10n.settingsSbpEmpty,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        for (final method in _methods)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_balance_outlined),
            title: Text(
              [method.bank, method.mask]
                  .whereType<String>()
                  .where((part) => part.isNotEmpty)
                  .join(' '),
            ),
            subtitle: Text(
              _stateLabel(l10n, method),
              style: TextStyle(
                color: method.chargeable
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: method.isPending
                ? TextButton(
                    onPressed: _loading ? null : _check,
                    child: Text(l10n.settingsSbpCheck),
                  )
                : (method.isRevoked
                    ? null
                    : IconButton(
                        tooltip: l10n.settingsSbpDetach,
                        icon: const Icon(Icons.link_off),
                        onPressed: _loading ? null : () => _detach(method),
                      )),
          ),
        if (_pendingBinding != null && !_loading)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.settingsSbpPendingHint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _errorText(l10n, _error!),
            style: TextStyle(color: theme.colorScheme.error),
          ),
          TextButton(
            onPressed: _loading ? null : () => _load(refresh: true),
            child: Text(l10n.retry),
          ),
        ],
      ],
    );
  }
}

