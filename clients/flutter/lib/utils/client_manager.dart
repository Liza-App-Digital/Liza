import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:collection/collection.dart';
import 'package:desktop_notifications/desktop_notifications.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_html/html.dart' as html;

import 'package:liza/config/app_config.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/auth_diagnostics.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/mcp_connections.dart';
import 'package:liza/utils/custom_http_client.dart';
import 'package:liza/utils/init_with_restore.dart';
import 'package:liza/utils/platform_infos.dart';
import 'matrix_sdk_extensions/flutter_matrix_dart_sdk_database/builder.dart';

abstract class ClientManager {
  static const String clientNamespace = 'im.fluffychat.store.clients';

  /// Stores the last client initialization error (if any) so the UI can
  /// display it instead of showing a blank gray/black screen.
  static Object? initializationError;
  static StackTrace? initializationErrorStack;

  static Future<List<Client>> getClients({
    bool initialize = true,
    required SharedPreferences store,
  }) async {
    // Reset previous initialization errors early so both the creation and
    // initialization phases can record failures.
    initializationError = null;
    initializationErrorStack = null;

    final clientNames = <String>{};
    try {
      final clientNamesList = store.getStringList(clientNamespace) ?? [];
      clientNames.addAll(clientNamesList);
    } catch (e, s) {
      Logs().w('Client names in store are corrupted', e, s);
      await store.remove(clientNamespace);
    }
    if (clientNames.isEmpty) {
      clientNames.add(PlatformInfos.clientName);
      await store.setStringList(clientNamespace, clientNames.toList());
    }

    // Create clients sequentially with individual error handling.
    // If one client fails (e.g. Keychain locked), the error is recorded
    // but the remaining clients still get a chance to be created.
    final clients = <Client>[];
    for (final name in clientNames) {
      try {
        final client = await createClient(name, store);
        clients.add(client);
      } catch (e, s) {
        Logs().e(
          'Failed to create client "$name" (e.g. Keychain locked)',
          e,
          s,
        );
        initializationError ??= e;
        initializationErrorStack ??= s;
      }
    }

    // If every client failed to create, surface the error so main()'s catch
    // block can provide a placeholder client and the router navigates to
    // /init-error instead of crashing with an empty clients list.
    if (clients.isEmpty && initializationError != null) {
      Error.throwWithStackTrace(
        initializationError!,
        initializationErrorStack!,
      );
    }

    if (initialize) {
      await Future.wait(
        clients.map((client) async {
          try {
            await client.initWithRestore(
              onMigration: () async {
                final l10n = await lookupL10n(
                  PlatformDispatcher.instance.locale,
                );
                sendInitNotification(
                  l10n.databaseMigrationTitle,
                  l10n.databaseMigrationBody,
                );
              },
            );
          } catch (e, s) {
            Logs().e('Unable to initialize client', e, s);
            initializationError ??= e;
            initializationErrorStack ??= s;
          }
        }),
      );
    }
    if (clients.length > 1 && clients.any((c) => !c.isLogged())) {
      final loggedOutClients = clients.where((c) => !c.isLogged()).toList();
      for (final client in loggedOutClients) {
        Logs().w(
          'Multi account is enabled but client ${client.userID} is not logged in. Removing...',
        );
        clientNames.remove(client.clientName);
        clients.remove(client);
      }
      await store.setStringList(clientNamespace, clientNames.toList());
    }
    return clients;
  }

  static Future<void> addClientNameToStore(
    String clientName,
    SharedPreferences store,
  ) async {
    final clientNamesList = store.getStringList(clientNamespace) ?? [];
    clientNamesList.add(clientName);
    await store.setStringList(clientNamespace, clientNamesList);
  }

  static Future<void> removeClientNameFromStore(
    String clientName,
    SharedPreferences store,
  ) async {
    final clientNamesList = store.getStringList(clientNamespace) ?? [];
    clientNamesList.remove(clientName);
    await store.setStringList(clientNamespace, clientNamesList);
  }

  static NativeImplementations get nativeImplementations => kIsWeb
      ? NativeImplementationsWebWorker(
          Uri.parse('native_executor.js'),
          timeout: const Duration(minutes: 1),
        )
      : NativeImplementationsIsolate(
          compute,
          vodozemacInit: () => vod.init(wasmPath: './assets/assets/vodozemac/'),
        );

  static Future<Client> createClient(
    String clientName,
    SharedPreferences store,
  ) async {
    final shareKeysWith = AppSettings.shareKeysWith.value;
    final enableSoftLogout = AppSettings.enableSoftLogout.value;

    final androidSdk = PlatformInfos.isAndroid
        ? await AuthDiagnostics.getAndroidSdkVersion()
        : null;

    final client = Client(
      clientName,
      httpClient: CustomHttpClient.createHTTPClient(
        androidSdkVersion: androidSdk,
      ),
      verificationMethods: {
        KeyVerificationMethod.numbers,
        if (kIsWeb || PlatformInfos.isMobile || PlatformInfos.isLinux)
          KeyVerificationMethod.emoji,
      },
      importantStateEvents: <String>{
        // To make room emotes work
        'im.ponies.room_emotes',
        // Скрытие чатов (чат обсуждений канала, сторис-комнаты) держится на
        // этом state-событии. SDK хранит в памяти только «важные» state для
        // partial-комнат (client.dart: !room.partial || importantStateEvents),
        // а таймлайн скрытого чата пользователь не открывает — без записи
        // здесь getState возвращал null и isHiddenChat молча давал false,
        // из-за чего чат обсуждений всплывал в списке после тихого join.
        'com.liza.chat.topology',
        // Маркер чата-запроса к Лизе: на нём держится закрепление основного
        // чата с Лизой (isLizaAssistantRoom) в списке — partial-комнаты.
        'com.liza.assistant.request',
        // Скрытие отдельных участников из списка (LABA-2381) держится на этом
        // room state. Без записи здесь partial-комната вернула бы getState=null
        // и скрытый участник всплывал бы в списке (тот же класс, что topology).
        'com.liza.chat.hidden_members',
        // Запрет копирования/пересылки/сохранения (LABA-2541). Тот же класс,
        // третий рецидив: без записи здесь `Room.noForwards` в partial-комнате
        // читался как false, и защита молча не действовала до открытия
        // таймлайна (первый кадр чата, тред по прямой ссылке, экран настроек,
        // изолят пушей).
        //
        // ⚠️ Промоушен типа ПОСТФАКТУМ — миграционное событие, а не бесплатная
        // строка. Запись роутится по коробкам БД по этому набору В МОМЕНТ
        // ЗАПИСИ (matrix_sdk_database.dart: _preloadRoomStateBox vs
        // _nonPreloadRoomStateBox), холодный старт читает только preload-бокс, а
        // `Room.postLoad()` ИСКЛЮЧАЕТ важные типы из выборки. Значит строка,
        // сохранённая до этой правки, не читается НИ ОДНИМ путём, пока сервер не
        // пришлёт state заново. `postLoad()` её не спасёт — не пытайся чинить им.
        // Здесь это осознанно принято: на момент правки во всём проде флаг
        // `enabled:true` был ровно в одной комнате, где единственный участник —
        // создатель с PL 100 (освобождён в любом случае), то есть потерять
        // защиту было некому. Новый такой тип вноси СРАЗУ, в коммите первого
        // использования.
        channelNoForwardsState,
        // Список подключённых MCP-расширений (витрина «MCP-подключения»).
        // ЧЕТВЁРТЫЙ рецидив того же класса — и первый, пойманный не тестом, а
        // владельцем: «нажимаю плюсик, но ничего не происходит». Запись на
        // сервер проходила (там лежал enabled:["vkusvill"]), а обратно в UI
        // состояние не доезжало: DM с Лизой на экране настроек не открыт, то
        // есть комната partial, и getState отдавал null.
        //
        // ⚠️ Внесено ПОСТФАКТУМ — и одного этого НЕ ХВАТИЛО. Расчёт был
        // «пользователь переключит тумблер, перезапись уедет уже в
        // preload-бокс, и всё сойдётся». Расчёт ОПРОВЕРГНУТ на живом проде:
        // Synapse дедуплицирует state-событие с идентичным содержимым
        // (`EventCreationHandler.deduplicate_state_event` — тот же отправитель
        // + равный canonical-JSON ⇒ возвращается ПРЕЖНЕЕ событие, новое не
        // персистится). Проверено запросом за пользователя: повторный PUT
        // `{"enabled":["vkusvill"]}` вернул event id, созданный часом ранее.
        // Значит перезаписи не происходит, в sync ничего не приходит, и экран
        // замирает НАВСЕГДА — ровно это владелец и увидел как мёртвый плюсик.
        //
        // Поэтому настоящее лекарство — не эта строка, а то, что витрина
        // спрашивает состояние У СЕРВЕРА и двигает его сама
        // (`McpConnections.fetch`, [[RL-mcp-connection-state-source]]). Строку
        // оставляем: она делает корректным ЗАПАСНОЙ, офлайновый путь чтения
        // для значений, записанных начиная с неё.
        mcpConnectionsStateType,
      },
      // Дефолтный SDK-фильтр не задаёт timeline.limit -> сервер применяет
      // спецификационный дефолт 10. Сторис-комната с длинным хвостом member/
      // redaction-событий вытесняла ещё живую сторис за это окно. Поднимаем
      // до 30 (умеренно: фильтр глобальный, не раздуваем каждый sync). Для
      // комнат с хвостом >30 добирает activeStoriesWithTimeline. lazyLoad
      // member-ов сохраняем (без него поедет загрузка участников).
      syncFilter: Filter(
        room: RoomFilter(
          state: StateFilter(lazyLoadMembers: true),
          timeline: StateFilter(limit: 30),
        ),
      ),
      logLevel: kReleaseMode ? Level.warning : Level.verbose,
      database: await flutterMatrixSdkDatabaseBuilder(clientName),
      supportedLoginTypes: {
        AuthenticationTypes.password,
        AuthenticationTypes.sso,
      },
      nativeImplementations: nativeImplementations,
      defaultNetworkRequestTimeout: const Duration(minutes: 30),
      // Дедлайн всего retry-цикла отправки события. Дефолт SDK 1 мин: при
      // мёртвом сокете сообщение висит "отправляется" до минуты, прежде чем
      // уйти в EventStatus.error (где есть кнопка "повторить"). 30s + сокет-
      // таймауты из custom_http_client дают честную ошибку быстрее. Ретраи
      // идемпотентны по txnId — дублей не будет.
      sendTimelineEventTimeout: const Duration(seconds: 30),
      enableDehydratedDevices: true,
      shareKeysWith:
          ShareKeysWith.values.singleWhereOrNull(
            (share) => share.name == shareKeysWith,
          ) ??
          ShareKeysWith.all,
      convertLinebreaksInFormatting: false,
      onSoftLogout: enableSoftLogout
          ? (client) async {
              try {
                await client.refreshAccessToken();
              } catch (e, s) {
                Logs().e('Soft logout recovery failed', e, s);
              }
            }
          : null,
    );
    _registerLizaCommands(client);
    return client;
  }

  /// Кастомные slash-команды Liza, чтобы они появлялись в подсказках при вводе «/».
  /// Команды обрабатывают боты (Лиза/BotFather) — регистрация лишь шлёт триггер
  /// обычным текстом (parseCommands: false, иначе рекурсия), бот отвечает карточками.
  static void _registerLizaCommands(Client client) {
    client.addCommand('myapps', (args, stdout) async {
      final room = args.room;
      if (room == null) return null;
      return room.sendTextEvent('/myapps', parseCommands: false);
    });
    // `/newapp` — создание mini App: BotFather отвечает карточкой «Внешний mini App».
    client.addCommand('newapp', (args, stdout) async {
      final room = args.room;
      if (room == null) return null;
      return room.sendTextEvent('/newapp', parseCommands: false);
    });
  }

  static void sendInitNotification(String title, String body) async {
    if (kIsWeb) {
      html.Notification(title, body: body);
      return;
    }
    if (Platform.isLinux) {
      await NotificationsClient().notify(
        title,
        body: body,
        appName: AppSettings.applicationName.value,
        hints: [NotificationHint.soundName('message-new-instant')],
      );
      return;
    }

    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin.initialize(
      InitializationSettings(
        android: const AndroidInitializationSettings('notifications_icon'),
        iOS: DarwinInitializationSettings(
          // E2E/local: не запрашиваем разрешение (иначе device-flow виснет на
          // нативном iOS-диалоге). Прод — isLocal compile-time false → как было.
          requestSoundPermission: !AppConfig.isLocal,
          requestAlertPermission: !AppConfig.isLocal,
          requestBadgePermission: !AppConfig.isLocal,
          defaultPresentSound: true,
          defaultPresentAlert: true,
          defaultPresentBadge: true,
          defaultPresentBanner: true,
          defaultPresentList: true,
        ),
      ),
    );

    flutterLocalNotificationsPlugin.show(
      0,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'error_message',
          'Error Messages',
          importance: Importance.high,
          priority: Priority.max,
        ),
        iOS: DarwinNotificationDetails(sound: 'liza_ding.aiff'),
      ),
    );
  }
}
