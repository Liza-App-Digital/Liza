import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_new_badger/flutter_new_badger.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/push_journal.dart';
import 'package:liza/utils/unseen_messages.dart';

/// Бейдж иконки приложения — единая точка для [BackgroundPush] и push_helper.
///
/// Бейдж — best-effort фича: его ошибки не должны становиться событиями
/// мониторинга (отказ юзера от бейджей — состояние, а не баг).
abstract final class AppBadge {
  /// Платформа отвергла обновление бейджа (юзер запретил бейджи в iOS,
  /// лаунчер Android без поддержки). Глушим вызовы до следующего resume:
  /// смена notification-тоггла в Настройках iOS НЕ перезапускает процесс,
  /// поэтому флаг обязан сбрасываться (см. didChangeAppLifecycleState).
  static bool _denied = false;
  static bool _deniedLogged = false;

  /// Нативный запрос notification-разрешений (apns) уже выполнен. До него
  /// бейджер на iOS звать нельзя: flutter_new_badger при notDetermined сам
  /// показывает системный диалог с единственной опцией .badge — отказ в нём
  /// гасит весь notification-authorization (alert/sound) до ручного
  /// включения в Настройках.
  static bool _permissionFlowDone = false;

  static void markPermissionRequested() => _permissionFlowDone = true;

  static void resetDenied() => _denied = false;

  /// Бейдж запрещён/недоступен на платформе (юзер отключил значки). Read-back
  /// рендера бейджа при взведённом латче не измеряет расхождение (setBadge был
  /// проглушён) — вызывающая сторона мониторинга должна пропускать этот случай.
  static bool get isDenied => _denied;

  /// Предикат «запись бейджа будет ПРОГЛОЧЕНА» — ровно те же два условия, по
  /// которым выходит [trySet]. Вынесен параметрами (а не читает статику), чтобы
  /// проверяться на host-VM: ветка iOS-латча иначе не покрывается вовсе —
  /// host-тесты идут на macOS, где `Platform.isIOS == false`.
  static bool writeSuppressed({
    required bool denied,
    required bool isIOS,
    required bool permissionFlowDone,
  }) =>
      denied || (isIOS && !permissionFlowDone);

  /// Запись бейджа ПРОГЛОЧЕНА, а не выполнена: либо платформа отказала
  /// (`_denied`), либо мы ещё до permission-латча на iOS. Второй случай важен
  /// отдельно: `trySet` из-под него выходит молча, `_denied` при этом остаётся
  /// `false`, поэтому read-back сравнивал бы Dart-счёт с числом, оставленным NSE,
  /// — гарантированный ложняк на холодном старте до `markPermissionRequested()`.
  static bool get isWriteSuppressed => writeSuppressed(
        denied: _denied,
        isIOS: !kIsWeb && Platform.isIOS,
        permissionFlowDone: _permissionFlowDone,
      );

  /// Монотонный счётчик ФАКТИЧЕСКИ выполненных записей бейджа. Нужен для
  /// честного read-back: писателей бейджа как минимум четыре (onSync-подписка на
  /// каждый клиент, resume, push_helper, cancelNotification — последний намеренно
  /// пишет `N−1`), все fire-and-forget и без общего гарда. Пока измеряющая
  /// сторона ждёт `getBadge()`, любой из них может переписать бейдж, и read-back
  /// увидит ЧУЖОЕ число. Сверять `writeSeq` до и после — значит отличить «бейдж
  /// залип» (seq не менялся, значение всё равно другое) от «нас обогнали»
  /// (seq вырос). Без этого детектор рапортовал соседние целые (delta==1 в 87%
  /// случаев, двунаправленно у одного юзера) — то есть измерял собственную гонку.
  static int get writeSeq => _writeSeq;
  static int _writeSeq = 0;
  static int? _lastJournaledCount;

  /// Канал к нативному APNs-плагину (iOS `ApnsPushPlugin` / macOS
  /// `MacApnsPushPlugin`) — по нему число видимых непрочитанных уезжает в App
  /// Group, откуда его читают NSE (закрытое приложение) и `AppDelegate`
  /// (macOS foreground-banner). Это единственный способ дать нативному
  /// фон-пути КЛИЕНТСКОЕ число вместо сырого серверного `counts.unread`.
  static const MethodChannel _apnsChannel = MethodChannel(
    'com.prodamus.laba.liza/apns',
  );

  /// Клиент-авторитетное число для бейджа: видимые в списке чатов
  /// непрочитанные/приглашённые комнаты. `null`, если клиент ещё не синкался
  /// (`prevBatch == null`) — тогда `client.rooms` неполон, и считать нельзя
  /// (иначе занизим до нуля). Это ЕДИНАЯ формула для всех поверхностей бейджа
  /// (иконка, `number` Android-нотификации, App Group для NSE).
  static int? visibleUnreadCount(Client client) => client.prevBatch == null
      ? null
      : client.rooms.where((room) => room.countsTowardAppBadge).length;

  /// Единый источник истины для числа на бейдже: видимые в списке чатов
  /// непрочитанные/приглашённые комнаты (скрытые stories/topology-hidden не
  /// в счёт — их нельзя открыть и прочитать). Перебивает серверный
  /// `counts.unread` из payload пуша, который про клиентскую топологию не знает.
  /// На несинканном клиенте `client.rooms` пуст — пропускаем, чтобы не затереть
  /// бейдж нулём из фонового изолята без состояния.
  static Future<void> refreshFrom(Client client) async {
    // Порядок «квитанция vs lastEvent» для комнат с частичной квитанцией
    // считается из локальной БД асинхронно — ДО подсчёта, иначе
    // `countsTowardAppBadge` ушёл бы в ts-фолбэк SDK и выкинул комнату.
    await UnseenOrderCache.reconcile(client);
    final count = visibleUnreadCount(client);
    if (count == null) return;
    await trySet(count);
  }

  /// Персистит клиентское число в App Group (iOS/macOS) — там его читает NSE
  /// при закрытом приложении. Пишем ТОЛЬКО целое число (атомарно), без набора
  /// roomId: инкремент/набор в NSE давал бы cross-process гонки и двойной счёт.
  /// Best-effort: провал канала не критичен (в фон-изоляте плагин может быть
  /// не зарегистрирован). Пишется при КАЖДОМ trySet, поэтому в App Group всегда
  /// последнее клиентское число, а не серверное.
  static Future<void> _persistCount(int count) async {
    if (kIsWeb || !(Platform.isIOS || Platform.isMacOS)) return;
    try {
      await _apnsChannel.invokeMethod('saveBadgeCount', {'count': count});
    } on PlatformException {
      // best-effort
    } on MissingPluginException {
      // фоновый изолят без зарегистрированного плагина — не критично
    }
  }

  /// Человекочитаемая расшифровка ответа `getNotificationSettings` (iOS/macOS).
  ///
  /// Вынесена ЧИСТОЙ функцией (без обращения к каналу), чтобы проверяться на
  /// host-VM: сам нативный вызов в тесте недоступен, а именно расшифровка —
  /// то, что читает человек в логе пользователя.
  ///
  /// Коды — сырые `rawValue` UserNotifications:
  /// `UNAuthorizationStatus` (0 notDetermined, 1 denied, 2 authorized,
  /// 3 provisional, 4 ephemeral) и `UNNotificationSetting`
  /// (0 notSupported, 1 disabled, 2 enabled).
  @visibleForTesting
  static String describeNotificationSettings(Map<Object?, Object?> raw) {
    const auth = {
      0: 'notDetermined',
      1: 'denied',
      2: 'authorized',
      3: 'provisional',
      4: 'ephemeral',
    };
    const setting = {0: 'notSupported', 1: 'disabled', 2: 'enabled'};
    String s(String key, Map<int, String> names) {
      final v = raw[key];
      return v is int ? (names[v] ?? 'unknown($v)') : 'absent';
    }

    return 'auth=${s('authorization', auth)} '
        'alert=${s('alert', setting)} '
        'badge=${s('badge', setting)} '
        'sound=${s('sound', setting)}';
  }

  /// Спросить ОС о фактических настройках уведомлений и залогировать ОДНОЙ
  /// строкой. Зовётся на resume, а не на каждый sync — это диагностика, а не
  /// телеметрия.
  ///
  /// Зачем: по логу пользователя было НЕВОЗМОЖНО отличить «система подавила
  /// бейдж» от «мы его не записали». `monitoring.dart` не логирует ничего,
  /// `AppBadge` — одну строку и только на `PlatformException`, которого на
  /// macOS не бывает (см. [describeNotificationSettings]). Инцидент 2026-09-09:
  /// в 6263-строчном логе за 19 дней не нашлось ни одной строки про бейдж.
  ///
  /// Возвращает сырой `UNAuthorizationStatus` (или `null`, если узнать не
  /// удалось) — по нему resume шлёт сигнал `os_denied` в мониторинг.
  static Future<int?> logNotificationSettings() async {
    if (kIsWeb || !(Platform.isIOS || Platform.isMacOS)) return null;
    try {
      final raw = await _apnsChannel.invokeMethod('getNotificationSettings');
      if (raw is Map) {
        Logs().i('[Badge] os settings: ${describeNotificationSettings(raw)}');
        final authorization = raw['authorization'];
        return authorization is int ? authorization : null;
      }
    } on PlatformException catch (e) {
      Logs().i('[Badge] os settings недоступны: ${e.code}');
    } on MissingPluginException {
      // Сборка старее той, где метод появился (iOS `ApnsPushPlugin` / macOS
      // `MacApnsPushPlugin`) — диагностики просто не будет, ронять нельзя.
    }
    return null;
  }

  /// `UNAuthorizationStatus.denied`.
  static const int authorizationDenied = 1;

  /// Форс перерисовки Dock на macOS (K-A): `NSApp.dockTile.display()`. Без него
  /// иконка при активном окне может не показать свежий `badgeLabel`. Best-effort.
  static Future<void> _refreshDockBadge() async {
    try {
      await _apnsChannel.invokeMethod('refreshDockBadge');
    } on PlatformException {
      // best-effort
    } on MissingPluginException {
      // фон-изолят без плагина
    }
  }

  /// Выставить бейдж в [count] (0 — убрать). Ошибки платформы гасятся:
  /// на iOS removeBadge — тот же setBadgeCount(0) и тоже кидает
  /// PERMISSION_DENIED, поэтому через try/catch идут оба вызова.
  static Future<void> trySet(int count) async {
    // Персист в App Group идёт ВСЕГДА (до permission-латча и независимо от
    // него): запись числа в разделяемый контейнер не требует badge-permission,
    // а NSE обязан видеть свежее клиентское число, даже если сам бейдж на
    // иконке пользователь запретил.
    await _persistCount(count);
    // Снятие бейджа (count == 0) пробуем ВСЕГДА, даже под _denied-латчем:
    // иначе один PERMISSION_DENIED от setBadge навсегда заклинивал бы залипшую
    // «1» до resume — removeBadge не давал бы её снять. Установка (>0) под
    // латчем по-прежнему глушится, чтобы не спамить платформенными ошибками.
    if (_denied && count != 0) return;
    if (Platform.isIOS && !_permissionFlowDone) return;
    try {
      if (count == 0) {
        await FlutterNewBadger.removeBadge();
      } else {
        await FlutterNewBadger.setBadge(count);
      }
      // Успешный вызов — латч самозаживает (не ждём resetDenied на resume).
      _denied = false;
      _writeSeq++;
      // В журнал — только СМЕНА числа: запись идёт на каждый sync, и без этого
      // бейдж вытеснил бы из кольца журнала всё остальное. Это факт записи, а
      // не отрисовки (read-back на macOS тавтологичен).
      if (count != _lastJournaledCount) {
        _lastJournaledCount = count;
        PushJournal.instance.record(PushStage.badge, value: count);
      }
      // K-A (macOS): dockTile.badgeLabel выставлен, но Dock может не
      // перерисоваться при frontmost-окне — форсим перерисовку нативно.
      if (Platform.isMacOS) await _refreshDockBadge();
    } on PlatformException catch (e) {
      _denied = true;
      if (!_deniedLogged) {
        _deniedLogged = true;
        Logs().i('[Badge] disabled until resume: ${e.code}');
      }
    } on MissingPluginException {
      _denied = true;
    }
  }
}
