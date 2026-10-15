import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/composer_draft.dart';
import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/utils/support_intent.dart';
import 'package:liza/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';

export 'package:liza/utils/support_intent.dart';

// Входов в поддержку четыре (меню аватара, «+» на rail, плашка на «Компаниях»,
// «Удалить компанию через поддержку»), а гейт один на клиента — UI-уровня:
// второй тап в 300-мс окне до показа LoadingDialog не открывает второй диалог
// и второй переход. Дедуп самого DM — в `ensureDirectChat`.
final _opening = Expando<bool>('openSupportChat');

/// Подмена старта DM для стражей, у которых нет доступа к параметру `start`
/// (меню зовёт `requestCompanyDeletion(context, room)` без инъекций): реальный
/// `startDirectChat` ждёт комнату в sync, которого в widget-тесте нет.
@visibleForTesting
Future<String> Function(String mxid)? supportChatStartOverride;

/// Открыть чат с ботом поддержки: создать (или переиспользовать) DM и перейти
/// в него. Кросс-инстанс — DM инициирует клиент со своего homeserver, бот
/// живёт на bots.liza.ru (федерация, как @botfather).
///
/// [composerDraft] — текст, который ляжет в композер открывшегося чата
/// (LABA-2533: готовая заявка «удалить компанию»). Ничего не отправляется —
/// отправляет пользователь. Пишется только после успешного старта DM и до
/// перехода, иначе `ChatController._loadDraft` его не увидит.
///
/// [intent] — намерение для бота ([supportIntentStateType]). Сбой `PUT /state`
/// в существующий DM не отменяет переход: чат откроется без карточки, как у
/// старых сборок, а пользователь увидит SnackBar.
Future<void> openSupportChat(
  BuildContext context, {
  String? composerDraft,
  SupportIntent? intent,
  @visibleForTesting Client? client,
  @visibleForTesting Future<String> Function(String mxid)? start,
}) async {
  start ??= supportChatStartOverride;
  final matrix = Matrix.of(context);
  final activeClient = client ?? matrix.client;
  if (_opening[activeClient] == true) return;
  _opening[activeClient] = true;
  final supportBot = AppConfig.supportBotMxidForHomeserver(
    activeClient.homeserver?.host,
  );
  final store = matrix.store;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final errorText = L10n.of(context).oopsSomethingWentWrong;
  // Тот же предикат, что у SDK внутри startDirectChat: DM есть → initial_state
  // не применится, интент ставим отдельным PUT.
  final existing = activeClient.getDirectChatFromUserId(supportBot) != null;
  try {
    var intentFailed = false;
    final result = await showFutureLoadingDialog<String>(
      context: context,
      future: () async {
        final roomId =
            await (start?.call(supportBot) ??
                activeClient.ensureDirectChat(
                  supportBot,
                  initialState: intent == null || existing
                      ? null
                      : [
                          StateEvent(
                            type: supportIntentStateType,
                            stateKey: '',
                            content: intent.content,
                          ),
                        ],
                ));
        if (intent != null && existing) {
          try {
            await activeClient.setRoomStateWithKey(
              roomId,
              supportIntentStateType,
              '',
              intent.content,
            );
          } catch (e, s) {
            Logs().w(
              '[SupportChat] интент ${intent.wireValue} не записан',
              e,
              s,
            );
            intentFailed = true;
          }
        }
        return roomId;
      },
    );
    final roomId = result.result;
    if (roomId == null || !context.mounted) return;
    if (intentFailed) {
      messenger?.showSnackBar(SnackBar(content: Text(errorText)));
    }
    if (composerDraft != null) {
      await writeComposerDraft(store, roomId, composerDraft);
      if (!context.mounted) return;
    }
    context.go('/rooms/$roomId');
  } finally {
    _opening[activeClient] = null;
  }
}

/// «Создать компанию» (rail-«+», плашка на чипе «Компании»): попап с описанием
/// компаний → «Оставить заявку» открывает чат поддержки сразу в сборе заявки.
/// Своя адаптивная обёртка, а не `showOkCancelAlertDialog`: тот режет ширину до
/// 256 и не прокручивается, а текст постановщика — ~520 символов в 4 абзаца.
/// Спека: docs/superpowers/specs/2026-10-14-create-company-popup-design.md.
Future<void> confirmCreateCompanyRequest(BuildContext context) async {
  // Второго попапа от двойного тапа не будет без своего гейта: push маршрута
  // глушит указатели до следующего кадра, а дальше вход закрыт барьером.
  final l10n = L10n.of(context);
  final confirmed = await showAdaptiveDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (context) => AlertDialog.adaptive(
      scrollable: true,
      title: Text(l10n.createCompanyViaSupport),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(
          l10n.createCompanyIntroText,
          key: const ValueKey('create_company_intro_text'),
        ),
      ),
      actions: [
        AdaptiveDialogAction(
          key: const ValueKey('create_company_intro_cancel'),
          onPressed: () => Navigator.of(context).pop<bool>(false),
          child: Text(l10n.cancel),
        ),
        AdaptiveDialogAction(
          key: const ValueKey('create_company_intro_request'),
          onPressed: () => Navigator.of(context).pop<bool>(true),
          autofocus: true,
          child: Text(l10n.createCompanyLeaveRequest),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await openSupportChat(context, intent: SupportIntent.createCompanyRequest);
}
