// GlitchTip #92 (iOS 3772): `showFutureLoadingDialog` ждёт до 300 мс, прежде
// чем показать диалог, и лишь потом зовёт `showAdaptiveDialog(context)`. Если
// вызывающий виджет (строка участника, аватар в ленте) за это время
// размонтирован, Navigator.of по мёртвому context падал «Null check operator»
// (release) / FlutterError (debug).
//
// Red-proof: убрать в future_loading_dialog.dart строку
// `if (!context.mounted) return Result.capture(futureExec);` → тест краснеет
// исключением из showAdaptiveDialog.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/widgets/future_loading_dialog.dart';

void main() {
  testWidgets(
    'вызывающий размонтирован за время задержки → без исключения, операция '
    'доводится и её результат возвращается',
    (tester) async {
      late BuildContext callerContext;
      final showCaller = ValueNotifier(true);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: showCaller,
              builder: (context, show, _) => show
                  ? Builder(
                      builder: (context) {
                        callerContext = context;
                        return const SizedBox.shrink();
                      },
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      // L10n грузится асинхронно — home строится не в первом кадре.
      await tester.pumpAndSettle();

      final operation = Completer<String>();
      final result = showFutureLoadingDialog<String>(
        context: callerContext,
        future: () => operation.future,
      );

      showCaller.value = false;
      await tester.pump();
      expect(callerContext.mounted, isFalse);

      // Истекает 300-мс задержка — момент, где раньше был Navigator.of.
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byType(LoadingDialog<String>), findsNothing);

      operation.complete('done');
      await tester.pump();
      expect((await result).asValue?.value, 'done');
    },
  );
}
