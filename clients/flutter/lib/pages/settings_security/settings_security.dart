import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/account_delete_service.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:liza/widgets/app_lock.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';
import 'delete_account_dialog.dart';
import 'settings_security_view.dart';

class SettingsSecurity extends StatefulWidget {
  const SettingsSecurity({super.key});

  @override
  SettingsSecurityController createState() => SettingsSecurityController();
}

class SettingsSecurityController extends State<SettingsSecurity> {
  void setAppLockAction() async {
    if (AppLock.of(context).isActive) {
      AppLock.of(context).showLockScreen();
    }
    final newLock = await showTextInputDialog(
      useRootNavigator: false,
      context: context,
      title: L10n.of(context).pleaseChooseAPasscode,
      message: L10n.of(context).pleaseEnter4Digits,
      cancelLabel: L10n.of(context).cancel,
      validator: (text) {
        if (text.isEmpty || (text.length == 4 && int.tryParse(text)! >= 0)) {
          return null;
        }
        return L10n.of(context).pleaseEnter4Digits;
      },
      keyboardType: TextInputType.number,
      obscureText: true,
      maxLines: 1,
      minLines: 1,
      maxLength: 4,
    );
    if (newLock != null) {
      await AppLock.of(context).changePincode(newLock);
    }
  }

  void deleteAccountAction() async {
    // Matrix/L10n берём ДО первого await: после деактивации роутер штатно
    // уносит этот виджет, и обращение к context на шаге логаута было бы
    // обращением к размонтированному State.
    final matrix = Matrix.of(context);
    final l10n = L10n.of(context);
    final userId = matrix.client.userID!;

    if (await showOkCancelAlertDialog(
          useRootNavigator: false,
          context: context,
          title: l10n.warning,
          message: l10n.deactivateAccountWarning,
          okLabel: l10n.ok,
          cancelLabel: l10n.cancel,
          isDestructive: true,
        ) ==
        OkCancelResult.cancel) {
      return;
    }
    if (!mounted) return;

    // Ника может не быть в кэше, а профиль ходит в сеть — показываем localpart
    // как в шапке настроек, лишь бы человек видел, ЧЕЙ аккаунт удаляют.
    final confirmed = await showDeleteAccountDialog(
      context,
      accountTitle: userId.localpart ?? userId,
      accountLogin: userId,
    );
    if (!confirmed || !mounted) {
      return;
    }
    // Не штатный /account/deactivate: он требует пароль (UIA), которого у
    // ProdamusID/OTP-пользователя нет. Удаляет auth-proxy, см. сервис.
    final service = AccountDeleteService(
      baseUrl: AppConfig.authProxyBaseUrl,
      accessTokenProvider: () => matrix.client.accessToken,
      serverNameProvider: () => userId.domain ?? '',
    );
    await deleteAccountAndLogout(
      delete: service.delete,
      markExplicitLogout: matrix.markExplicitLogout,
      unmarkExplicitLogout: matrix.unmarkExplicitLogout,
      logout: matrix.client.logout,
      runWithProgress: (action) => showFutureLoadingDialog(
        context: context,
        delay: false,
        future: action,
      ),
      isMounted: () => mounted,
    );
  }

  Future<void> dehydrateAction() => Matrix.of(context).dehydrateAction(context);

  void changeShareKeysWith(ShareKeysWith? shareKeysWith) async {
    if (shareKeysWith == null) return;
    AppSettings.shareKeysWith.setItem(shareKeysWith.name);
    Matrix.of(context).client.shareKeysWith = shareKeysWith;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => SettingsSecurityView(this);
}
