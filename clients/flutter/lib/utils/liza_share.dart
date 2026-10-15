import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:share_plus/share_plus.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/company_invite_gate.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/qr_code_viewer.dart';
import '../widgets/matrix.dart';

abstract class LizaShare {
  static Future<void> share(
    String text,
    BuildContext context, {
    bool copyOnly = false,
  }) async {
    if (PlatformInfos.isMobile && !copyOnly) {
      // findRenderObject даёт RenderBox только у уже отрисованного виджета;
      // строка «Пригласить людей» может звать share из не-Box-контекста —
      // тогда просто отдаём share-лист без sharePositionOrigin (iPad-якорь).
      final renderObject = context.findRenderObject();
      final origin = renderObject is RenderBox && renderObject.hasSize
          ? renderObject.localToGlobal(Offset.zero) & renderObject.size
          : null;
      await SharePlus.instance.share(
        ShareParams(text: text, sharePositionOrigin: origin),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(L10n.of(context).copiedToClipboard)));
    return;
  }

  /// Создаёт (идемпотентно) invite-ссылку текущего пользователя и открывает
  /// НАТИВНОЕ меню шеринга с текстом-приглашением. Используется строкой
  /// «Пригласить людей» и кнопкой «Пригласить» у контакта.
  ///
  /// На инстансе-компании ссылка вводит в компанию — без права `invite` в
  /// главном пространстве вместо ссылки плашка ([ensureCanInviteToLiza]).
  static Future<void> shareInvitePeople(BuildContext context) async {
    if (!ensureCanInviteToLiza(context)) return;
    final client = Matrix.of(context).client;
    final userId = client.userID;
    if (userId == null) return;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () => AuthProxyService().createUserInvite(
        targetUserId: userId,
        accessToken: client.accessToken ?? '',
      ),
    );
    final info = result.result;
    if (info == null || !context.mounted) return;
    final text = L10n.of(context).inviteMessageText(info.url);
    await LizaShare.share(text, context);
  }

  static Future<void> shareInviteLink(BuildContext context) async {
    if (!ensureCanInviteToLiza(context)) return;
    final client = Matrix.of(context).client;
    final userId = client.userID!;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () => AuthProxyService().createUserInvite(
        targetUserId: userId,
        accessToken: client.accessToken ?? '',
      ),
    );
    final info = result.result;
    if (info == null || !context.mounted) return;
    showQrCodeViewer(context, userId, inviteLink: info.url);
  }
}
