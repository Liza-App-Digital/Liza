import 'dart:developer';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/pages/chat_list/chat_list_body.dart';
import 'package:liza/pages/homeserver_picker/homeserver_picker.dart';
import 'package:liza/pages/login/login_view.dart';
import 'package:liza/widgets/matrix.dart';

import 'e2e_config.dart';

/// UI-флоу Liza под локальный стек (APP_ENV=local): вход прямым
/// Matrix-логином через кнопку «Локальный сервер (пароль)».
extension LizaE2eFlows on WidgetTester {
  /// Ожидание для live-биндинга: pumpAndSettle зависает на бесконечных
  /// анимациях (LinearProgressIndicator), а совсем без pump кадры и жесты
  /// не прокачиваются. Поэтому — цикл коротких pump'ов.
  ///
  /// ВАЖНО: не передавать сюда finder с `.first`/`.last` — на пустом дереве
  /// их evaluate() кидает «Bad state: No element» вместо пустого списка.
  Future<void> waitUntil(
    Finder finder, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final end = DateTime.now().add(timeout);
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) {
        // Диагностика в сообщении: какие тексты сейчас на экране.
        final visible = find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .whereType<String>()
            .where((t) => t.trim().isNotEmpty)
            .take(30)
            .join(' | ');
        throw Exception('Не дождались $finder. На экране: $visible');
      }
      await pump(const Duration(milliseconds: 100));
    }
  }

  /// Доводит приложение до списка чатов: если открыт HomeserverPicker —
  /// логинится под [E2eConfig.userA]; если сессия уже есть — просто ждёт.
  Future<void> ensureLizaHome({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final picker = find.byType(HomeserverPicker);
    final chatList = find.byType(ChatListViewBody);
    final end = DateTime.now().add(timeout);

    log('Ждём HomeserverPicker или ChatListViewBody...', name: 'liza-e2e');
    do {
      if (DateTime.now().isAfter(end)) {
        throw Exception('Не дождались HomeserverPicker/ChatListViewBody');
      }
      await pump(const Duration(milliseconds: 100));
    } while (picker.evaluate().isEmpty && chatList.evaluate().isEmpty);

    if (chatList.evaluate().isNotEmpty) {
      // Debug-сборка делит хранилище с ручными запусками: найденная сессия
      // может оказаться прод-аккаунтом владельца. Сценарий публикует, шлёт и
      // создаёт комнаты — на проде это недопустимо (LABA-2617: прогон создал
      // комнату у владельца на synapse.liza.laba.prodamus.tech).
      final homeserver = Matrix.of(element(chatList.first)).client.homeserver;
      if (homeserver == null || !AppConfig.isLocalHost(homeserver.host)) {
        throw StateError(
          'e2e: найдена НЕ локальная сессия ($homeserver) — тест остановлен, '
          'чтобы не действовать от реального аккаунта. Запускай на чистом '
          'устройстве/симуляторе или разлогинь debug-сборку.',
        );
      }
      log('Сессия уже есть, логин не нужен', name: 'liza-e2e');
      await _dismissPushWarning();
      return;
    }

    log('Логинимся через «Локальный сервер (пароль)»', name: 'liza-e2e');
    await waitUntil(find.text('Локальный сервер (пароль)'));
    await tap(find.text('Локальный сервер (пароль)'));
    await pump(const Duration(milliseconds: 300));
    await waitUntil(
      find.byType(LoginView),
      timeout: const Duration(seconds: 20),
    );
    await pump(const Duration(milliseconds: 300));

    final fields = find.descendant(
      of: find.byType(LoginView),
      matching: find.byType(TextField),
    );
    await enterText(fields.at(0), E2eConfig.userA.name);
    await pump();
    await enterText(fields.at(1), E2eConfig.userA.password);
    await pump();
    await tap(
      find.descendant(
        of: find.byType(LoginView),
        matching: find.byType(ElevatedButton),
      ),
    );
    await pump(const Duration(milliseconds: 300));

    // Первый sync после логина бывает долгим.
    await waitUntil(
      find.byType(ChatListViewBody),
      timeout: const Duration(seconds: 90),
    );
    log('Залогинились, список чатов на экране', name: 'liza-e2e');
    await _dismissPushWarning();
  }

  /// В debug-сборке без push-провайдера может всплыть предупреждение —
  /// закрываем на любой локали (одно окно ожидания на все варианты).
  Future<void> _dismissPushWarning() async {
    const labels = [
      'Больше не показывать',
      'Do not show again',
      'DO NOT SHOW AGAIN',
    ];
    final end = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(end)) {
      for (final label in labels) {
        final finder = find.text(label);
        if (finder.evaluate().isNotEmpty) {
          await tap(finder);
          await pump(const Duration(milliseconds: 300));
          return;
        }
      }
      await pump(const Duration(milliseconds: 200));
    }
  }
}
