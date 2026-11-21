import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';

/// Маленькая ссылка под вводом телефона: ведёт на экран логина и пароля
/// для проверяющих (App Review). Основной вход по телефону она не заменяет.
class ReviewerLoginLink extends StatelessWidget {
  const ReviewerLoginLink({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: TextButton(
        onPressed: onPressed,
        child: Text(
          L10n.of(context).reviewerLogin,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
