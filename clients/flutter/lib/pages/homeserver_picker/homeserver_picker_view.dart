import 'package:flutter/material.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/pages/homeserver_picker/auth_outcome_view.dart';
import 'package:liza/pages/homeserver_picker/login_entry_actions.dart';
import 'package:liza/pages/homeserver_picker/login_entry_description.dart';
import 'package:liza/widgets/layouts/login_scaffold.dart';
import 'package:liza/widgets/matrix.dart';
import 'homeserver_picker.dart';

/// Высота вьюпорта, при которой экран рисуется в полный рост.
///
/// Ниже неё отступы и логотип ужимаются пропорционально: на ноутбучных
/// экранах (и на десктопной карточке 800px за вычетом AppBar) содержимому
/// не хватало места, и юр-сноска с кнопкой «Продолжить» уезжали за край.
const _comfortableHeight = 720.0;

/// Ниже этого ужимать бессмысленно — дальше включается прокрутка.
const _minDensity = 0.45;

class HomeserverPickerView extends StatelessWidget {
  final HomeserverPickerController controller;

  const HomeserverPickerView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LoginScaffold(
      enforceMobileMode: Matrix.of(
        context,
      ).widget.clients.any((client) => client.isLogged()),
      appBar: AppBar(
        centerTitle: true,
        // title hidden intentionally
        title: null,
      ),
      // Исход авторизации («нет доступа» / «ссылка недействительна») занимает
      // экран целиком: обычное содержимое с кнопками входа человеку здесь уже
      // не нужно — выход только через «Назад».
      body: controller.authOutcome != null
          ? AuthOutcomeView(
              outcome: controller.authOutcome!,
              requestAccessUrl: controller.requestAccessUrl,
              onRequestAccess: controller.requestAccessAction,
              onBack: controller.dismissAuthOutcome,
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                // Коэффициент плотности: 1.0 на просторном экране, меньше —
                // на низком. Им масштабируются ВСЕ вертикальные промежутки и
                // потолок логотипа, поэтому экран сжимается целиком, а не
                // обрезается снизу.
                final density = constraints.maxHeight.isFinite
                    ? (constraints.maxHeight / _comfortableHeight).clamp(
                        _minDensity,
                        1.0,
                      )
                    : 1.0;
                // Логотип — единственный элемент без естественного потолка:
                // при fit: fitWidth он растягивался на ~190px и первым съедал
                // высоту. Отдаём ему долю вьюпорта, а не всю ширину.
                final logoMaxHeight = constraints.maxHeight.isFinite
                    ? (constraints.maxHeight * 0.22).clamp(64.0, 180.0)
                    : 180.0;

                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight.isFinite
                          ? constraints.maxHeight
                          : 0,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        children: [
                          Container(
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                            ),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: logoMaxHeight,
                              ),
                              child: Hero(
                                tag: 'info-logo',
                                child: Image.asset(
                                  './assets/banner_transparent.png',
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: 24 * density),
                          Text(
                            'Liza',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          SizedBox(height: 12 * density),
                          Builder(
                            builder: (context) {
                              final compact = AppConfig.phoneAuthEnabled;
                              return Padding(
                                padding: EdgeInsets.symmetric(
                                  // В компактном режиме отступы уже: слоган
                                  // задуман одной строкой и на узком экране
                                  // иначе ужимается слишком мелко.
                                  horizontal: compact ? 16.0 : 32.0,
                                ),
                                // Первый экран совмещён с вводом
                                // телефона — описание подаётся двумя блоками,
                                // как в макете.
                                child: LoginEntryDescription(compact: compact),
                              );
                            },
                          ),
                          // Не Spacer: тот занимает ВЕСЬ остаток и на низкой
                          // карточке (десктоп, maxHeight 640) выталкивает
                          // нижний блок за край — юр-сноска обрезалась.
                          // Гибкий промежуток отдаёт место содержимому,
                          // когда его не хватает.
                          Flexible(child: SizedBox(height: 48 * density)),
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              32,
                              8 * density,
                              32,
                              16 * density,
                            ),
                            child: Column(
                              mainAxisSize: .min,
                              crossAxisAlignment: .stretch,
                              children: [
                                // Homeserver input hidden intentionally
                                // Ошибка входа теперь диагностична всегда —
                                // «нет доступа» больше не является ожидаемым
                                // исходом первого экрана.
                                if (controller.error != null)
                                  Padding(
                                    padding: EdgeInsets.only(
                                      bottom: 16 * density,
                                    ),
                                    child: Text(
                                      controller.error!,
                                      style: TextStyle(
                                        color: theme.colorScheme.error,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                LoginEntryActions(
                                  isLoading: controller.isLoading,
                                  onRegister: controller.registerAction,
                                  onSignIn: controller.authProxyLoginAction,
                                  // Отступы блока ввода ужимаются тем же
                                  // коэффициентом, что и остальной экран.
                                  density: density,
                                  // Страну по IP спрашиваем у auth-proxy —
                                  // локаль даёт язык, а не место (см.
                                  // PhoneCountryResolver).
                                  countryResolver: controller.countryResolver,
                                  // На prod/dev используется phone/email OTP
                                  // через auth-proxy текущего окружения.
                                  onSubmitPhone: AppConfig.phoneAuthEnabled
                                      ? controller.submitPhoneAction
                                      : null,
                                ),
                                // Локальная разработка (APP_ENV=local): вход паролем в
                                // локальный Synapse (OIDC локально нет). Минуя ProdamusID.
                                if (AppConfig.isLocal) ...[
                                  const SizedBox(height: 8),
                                  OutlinedButton.icon(
                                    onPressed: controller.isLoading
                                        ? null
                                        : () {
                                            // E2E_HOMESERVER — для эмуляторов, где
                                            // *.liza.local недоступен (Android:
                                            // http://localhost:8008 + adb reverse).
                                            controller
                                                    .homeserverController
                                                    .text =
                                                const String.fromEnvironment(
                                                  'E2E_HOMESERVER',
                                                  defaultValue:
                                                      'synapse.liza.local',
                                                );
                                            controller.checkHomeserverAction(
                                              legacyPasswordLogin: true,
                                            );
                                          },
                                    icon: const Icon(
                                      Icons.dns_outlined,
                                      size: 18,
                                    ),
                                    label: const Text(
                                      'Локальный сервер (пароль)',
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
