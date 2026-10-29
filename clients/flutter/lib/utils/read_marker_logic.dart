import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';

/// Чистая логика продвижения сепаратора «Непрочитанное» за собственные
/// сообщения (п.2.3). Сервер не шлёт m.read автору на его же событие, поэтому
/// room.fullyRead отстаёт на последнее ЧУЖОЕ сообщение и сепаратор всплывал
/// НАД своим свежим сообщением.
///
/// [visibleEvents] — события от НОВЫХ к старым (как timeline.events). [markerId]
/// — текущий eventId метки (обычно room.fullyRead). Возвращает новый eventId
/// метки:
/// - '' — если выше нет непрочитанных ЧУЖИХ сообщений (метку снять);
/// - eventId соседа, который старше первого непрочитанного чужого, — чтобы
///   черта легла ровно над ним, а свои свежие сообщения остались выше неё
///   (прочитаны);
/// - исходный [markerId] — если двигать не нужно (метка на новейшем событии,
///   не найдена или уже стоит верно).
String advanceReadMarkerPastMine(
  List<Event> visibleEvents,
  String markerId,
  String myUserId,
) {
  if (markerId.isEmpty) return markerId;
  final markerIdx = visibleEvents.indexWhere((e) => e.eventId == markerId);
  // markerIdx == 0 → метка на новейшем событии, «после» неё ничего нет.
  if (markerIdx <= 0) return markerId;

  // Самое СТАРОЕ непрочитанное чужое СООБЩЕНИЕ после метки (наибольший индекс
  // < markerIdx с чужим senderId). Идём от markerIdx-1 (старейшее в зоне) к 0.
  // State-события (вступление, смена имени) не «непрочитанное»: с частичной
  // квитанцией (Telegram-модель) метка иначе вставала бы над чужим join'ом.
  var firstUnreadOtherIdx = -1;
  for (var j = markerIdx - 1; j >= 0; j--) {
    if (visibleEvents[j].senderId != myUserId && !visibleEvents[j].isState) {
      firstUnreadOtherIdx = j;
      break;
    }
  }
  // Все события после метки — мои или служебные: сепаратор бессмыслен.
  if (firstUnreadOtherIdx == -1) return '';

  // Метка рисуется ПОД своим событием → ставим её на соседа, который СТАРШЕ
  // первого непрочитанного чужого (индекс +1).
  return visibleEvents[firstUnreadOtherIdx + 1].eventId;
}

/// Видны ли на экране новейшие сообщения (живой конец таймлайна) — решение по
/// ТЕКУЩИМ scroll-метрикам, а НЕ по кэш-флагу `_scrolledUp`.
///
/// Зачем (баг «аватарка прочтения у собеседника появляется только после нашего
/// ответа»): `_scrolledUp` выставляется по переходным layout-фреймам (mount,
/// появление клавиатуры, когда `maxScrollExtent` на миг > 0) и в маленьком чате
/// (контент помещается целиком) структурно не сбрасывается — `_updateScroll`
/// контроллер на `maxScrollExtent <= 0` рано выходил. Залипший `_scrolledUp`
/// глушил гейт отправки квитанции в `_sendReadMarkerNow` для ВСЕХ реактивных
/// вызовов (новое сообщение/resume/докрут), поэтому собеседник не видел нашу
/// `m.read`, пока мы не отправим сообщение (оно сбрасывало скролл вниз).
///
/// Новейшее видно, когда мы у живого конца таймлайна ([allowNewEvent]) и либо
/// весь контент помещается на экран (`maxScrollExtent <= 0`), либо скролл стоит
/// у низа (reverse-list: `pixels` ≈ 0; тот же порог 2.0, что и гистерезис в
/// `_updateScrollController`).
bool newestMessagesVisible({
  required double maxScrollExtent,
  required double pixels,
  required bool allowNewEvent,
}) {
  if (!allowNewEvent) return false;
  return maxScrollExtent <= 0 || pixels < 2.0;
}

/// План действий по квитанции/сепаратору «Непрочитанное» при ОТКРЫТИИ чата —
/// по позиции сепаратора в загруженном окне таймлайна.
///
/// История. LABA-1894 («залипание счётчика-бейджа»): при открытии чата, где
/// сепаратор уехал вверх (`readMarkerEventIndex > 1`), `_tryLoadTimeline`
/// скроллил к сепаратору и делал ранний `return` БЕЗ квитанции вовсе — гейт
/// `_scrolledUp` дальше глушил все реактивные вызовы, и счётчик залипал до
/// ручного докрута. Фикс 2026-07-31 слал квитанцию на ПОСЛЕДНЕЕ событие
/// («открытие = всё прочитано»). Запрос Саши Н. 2026-09-17 («увидел часть из 12,
/// вернулся — всё прочитано и пролистано вниз») это отменил: принята
/// Telegram-модель «прочитано = увидено».
///
/// Правило теперь: квитанция при открытии ОБЯЗАНА уйти (корень LABA-1894
/// сохраняем), но КУДА — зависит от позиции:
/// - сепаратор у низа (`index <= 1`) или его нет → на последнее событие
///   ([markLastEvent]), сепаратор снимается штатно;
/// - сепаратор уехал вверх (`index > 1`) → скроллим к нему
///   ([scrollToDivider]) и после позиционирования шлём квитанцию на новейшее
///   ВИДИМОЕ событие ([markVisibleAfterPosition]); сепаратор сохраняем
///   ([preserveDivider]) — он показывает, где мы остановились, и снимется,
///   когда пользователь докрутит до низа.
///
/// [readMarkerEventIndex] — позиция сепаратора в окне (как считает
/// `_tryLoadTimeline`): `-1` нет/не найден, `0`/`1` у низа, `>1` уехал вверх.
/// [canMarkLastEvent] — есть последнее событие и `timeline.allowNewEvent`.
typedef OpenChatReadMarkerPlan = ({
  bool scrollToDivider,
  bool markLastEvent,
  bool markVisibleAfterPosition,
  bool preserveDivider,
});

OpenChatReadMarkerPlan openChatReadMarkerPlan({
  required int readMarkerEventIndex,
  required bool canMarkLastEvent,
}) {
  final scrollToDivider = readMarkerEventIndex > 1;
  return (
    scrollToDivider: scrollToDivider,
    markLastEvent: canMarkLastEvent && !scrollToDivider,
    markVisibleAfterPosition: scrollToDivider,
    preserveDivider: scrollToDivider,
  );
}

/// Тег ленты для геометрии «видимости»: [index] — индекс в списке видимых
/// событий (reverse-list: меньший = новее), [eventId] — из `ValueKey` тега,
/// [rect] — прямоугольник строки В СИСТЕМЕ КООРДИНАТ viewport'а.
typedef VisibleTag = ({int index, String eventId, Rect rect});

/// Новейшее событие, реально увиденное (Telegram-модель «прочитано =
/// увидено»): строка считается увиденной, когда её НИЖНИЙ край внутри
/// viewport'а — сообщение дочитано до конца. Прежнее «пересечение > 0»
/// засчитывало 1 px верхушки: после открытия на сепараторе первое непрочитанное
/// выглядывало снизу и сразу уходило в квитанцию, и при следующем входе отсечка
/// вставала ПОСЛЕ него (Саша Н., 2026-10-28). Строка выше viewport'а
/// засчитывается, только когда до её низа докрутили. Смонтированность ничего не
/// значит: `ListView` держит `cacheExtent` за краем экрана. Порядок — по
/// индексу тега (не по позиции в `tagMap`: индексы там сдвигаются между
/// вставкой события и rebuild'ом, поэтому eventId берётся из ключа тега, а не
/// из `events[index]`).
String? newestVisibleEventId(Iterable<VisibleTag> tags, Size viewport) {
  final sorted = tags.toList()..sort((a, b) => a.index.compareTo(b.index));
  for (final tag in sorted) {
    if (tag.rect.height <= 0) continue;
    final bottom = tag.rect.bottom;
    if (bottom > 0 && bottom <= viewport.height + _subpixelTolerance) {
      return tag.eventId;
    }
  }
  return null;
}

const double _subpixelTolerance = 0.5;

/// Доля высоты viewport'а от верха, на которую при открытии чата встаёт
/// отсечка «Непрочитанное» (низ строки `m.fully_read`): как в Telegram — у
/// верха, сверху виден хвост прочитанного, ниже — начало непрочитанного.
const double unreadDividerViewportFraction = 0.22;

/// Новое значение `pixels`, при котором низ строки с отсечкой окажется на
/// [fraction] высоты viewport'а. [dividerBottom] — низ строки в координатах
/// viewport'а при текущих [pixels]. Лента `reverse`: рост `pixels` сдвигает
/// контент на экране ВНИЗ, поэтому сдвиг = цель − текущее положение. Clamp по
/// границам прокрутки: у края загруженной истории отсечка встанет ниже/выше
/// цели, но останется на экране.
double dividerScrollPixels({
  required double pixels,
  required double dividerBottom,
  required double viewportHeight,
  required double minScrollExtent,
  required double maxScrollExtent,
  double fraction = unreadDividerViewportFraction,
}) {
  final target = viewportHeight * fraction;
  return (pixels + target - dividerBottom).clamp(
    minScrollExtent,
    maxScrollExtent,
  );
}

/// Своё действие в чате (сообщение из композера, кнопка карточки бота,
/// XL-кнопка) → прокрутка к низу, чтобы ответ бота был виден без ручного
/// скролла (запрос Саши Н. 2026-09-17 «нажал кнопку, прокрутка к новому
/// сообщению не сработала»). Единая точка — local-echo из
/// `client.onTimelineEvent` (в отличие от `Timeline.onInsert` он приходит и
/// при `allowNewEvent == false`).
///
/// Скроллит ТОЛЬКО: моё, ещё отправляемое (`status.isSending` — synced-версия
/// с другого устройства не в счёт), видимое в ленте (`isVisibleInGui` режет
/// реакции, правки, redaction — реакция на сообщение тремя экранами выше не
/// должна утаскивать вниз) и из текущего контекста (главная лента vs тред).
/// Allowlist по `relationshipType == null` не подходит: он резал бы ответы
/// (reply) и callback карточек с кастомным `rel_type`.
bool shouldScrollDownOnOwnEcho(
  Event event, {
  required String? myUserId,
  required String roomId,
  required String? activeThreadId,
}) {
  if (myUserId == null) return false;
  if (event.room.id != roomId) return false;
  if (event.senderId != myUserId) return false;
  if (!event.status.isSending) return false;
  if (!event.isVisibleInGui) return false;
  if (activeThreadId == null) {
    return event.relationshipType != RelationshipTypes.thread;
  }
  return event.relationshipType == RelationshipTypes.thread &&
      event.relationshipEventId == activeThreadId;
}

/// Реакция `ChatController` на свой local-echo (см. [shouldScrollDownOnOwnEcho]).
enum OwnEchoScrollAction {
  /// Живая лента: прыгнуть к низу после ближайшего rebuild (флаг для updateView).
  deferJumpToBottom,

  /// Исторический контекст (`!allowNewEvent`): echo в такую ленту не попадает —
  /// перезагрузить таймлайн на живой конец (`scrollDown()`).
  reloadToLiveEnd,

  /// Лента грузится или перезагружается: ничего не делать.
  none,
}

/// Чистое решение для `_onOwnEcho`. `timeline == null` — штатное состояние в
/// момент echo, а не ошибка: сам `scrollDown()` обнуляет таймлайн на время
/// перезагрузки с исторического контекста, а SDK на ОДНУ отправку файла шлёт
/// несколько echo со `status.sending` (pending → encrypting → uploading →
/// send). Второе и последующие прилетают в окно перезагрузки; звать на них
/// `scrollDown()` нельзя — он разыменовывал `timeline!` и ронял чат каскадом
/// (GlitchTip #2042, сборка 3762, 3 падения за 44 мс). Делать тоже нечего:
/// перезагрузка на живой конец сама прыгнет к низу, а первичная загрузка
/// открывает ленту у низа.
OwnEchoScrollAction ownEchoScrollAction({required bool? allowNewEvent}) {
  if (allowNewEvent == null) return OwnEchoScrollAction.none;
  return allowNewEvent
      ? OwnEchoScrollAction.deferJumpToBottom
      : OwnEchoScrollAction.reloadToLiveEnd;
}

/// Что должен сделать scroll-listener чата по текущим метрикам.
enum ScrollUpdateAction {
  /// Ничего не менять (в т.ч. во время программного авто-скролла).
  none,

  /// Показать кнопку «вниз» (пользователь прокрутил выше низа): setState.
  setScrolledUpTrue,

  /// Пользователь докрутил к низу: сбросить флаг «вниз» и отправить квитанцию.
  setScrolledUpFalseAndMark,

  /// Контент помещается целиком у низа: сбросить флаг (если стоял) и досыл
  /// квитанции.
  markAtBottom,
}

/// Решение scroll-listener'а `_updateScrollController` по живым метрикам.
/// Вынесено из виджета, чтобы покрыть тестом инвариант против цикла «тряски».
///
/// Баг «экран трясётся в цикле при входе в чат с непрочитанным»: во время
/// программной прокрутки к сепаратору «Непрочитанное» (`scrollToIndex` из
/// `scroll_to_index`) listener дёргается на КАЖДОМ кадре анимации. В зоне
/// `pixels < 1` он звал `setReadMarker`, тот сбрасывал `readMarkerEventId` →
/// сепаратор (~48px) исчезал → менялась геометрия списка → поисковый цикл
/// `scrollToIndex` пересчитывал offset и прыгал заново → незатухающий цикл
/// (плюс `setState` в listener во время активной анимации давал двойной
/// рендер). Ключ фикса: пока идёт авто-скролл ([isAutoScrolling]), НЕ трогаем
/// layout вовсе — контроллер сам довезёт до цели и по завершении авто-скролла
/// сделает финальный notify, на котором listener доотправит квитанцию.
///
/// [scrolledUp] — текущее состояние флага в контроллере. Пороги (2.0/1.0)
/// совпадают с прежним `_updateScrollController` (гистерезис против
/// subpixel-осцилляции).
ScrollUpdateAction scrollControllerUpdateAction({
  required double maxScrollExtent,
  required double pixels,
  required bool allowNewEvent,
  required bool scrolledUp,
  required bool isAutoScrolling,
}) {
  // Пока контроллер сам анимирует прокрутку — молчим. Иначе layout-меняющий
  // побочный эффект (сброс маркера → исчезновение сепаратора) сорвёт цель
  // авто-скролла и запустит цикл.
  if (isAutoScrolling) return ScrollUpdateAction.none;

  if (maxScrollExtent <= 0 && allowNewEvent) {
    return ScrollUpdateAction.markAtBottom;
  }
  if (!allowNewEvent || (pixels > 2.0 && !scrolledUp)) {
    return ScrollUpdateAction.setScrolledUpTrue;
  }
  if (pixels < 1.0 && scrolledUp) {
    return ScrollUpdateAction.setScrolledUpFalseAndMark;
  }
  return ScrollUpdateAction.none;
}

/// Насколько пользователь СМОТРИТ на чат — единый источник и для квитанции
/// «прочитано», и для решения «глушить ли баннер по активной комнате».
///
/// - [full] — окно в фокусе (`resumed`): полная квитанция, баннер по открытому
///   чату не нужен.
/// - [partialOnly] — десктоп, окно видимо без фокуса ОС (`inactive`), экран не
///   заблокирован. На macOS `inactive` — это и окно на втором мониторе, и окно,
///   из-под браузера торчащее краем (движок шлёт `hidden` только когда не видно
///   НИ ОДНОГО пикселя), поэтому «смотрит» тут не доказано. Допускается лишь
///   частичная квитанция по явной прокрутке (жест = внимание); полная —
///   откладывается до `resumed`. Иначе локальный баннер из sync снимался бы
///   квитанцией через 0,3 с, и человек узнавал о сообщении от APNs через
///   минуты (заявка №31, 2026-09-18). Lock screen даёт тот же `inactive` —
///   квитанций нет вовсе (с серверной read-grace они глушили бы пуш на телефон).
/// - [none] — `paused`/`hidden`/`detached`, мобильный `inactive`.
enum ReadableForeground { none, partialOnly, full }

ReadableForeground readableForeground({
  required AppLifecycleState? lifecycle,
  required bool isDesktop,
  required bool screenLocked,
}) {
  if (lifecycle == AppLifecycleState.resumed) return ReadableForeground.full;
  if (isDesktop && lifecycle == AppLifecycleState.inactive && !screenLocked) {
    return ReadableForeground.partialOnly;
  }
  return ReadableForeground.none;
}

/// Решение гейта отправки квитанции по [readable] и типу квитанции. [isFull] —
/// квитанция «до последнего события» (гасит счётчик и снимает баннеры).
enum ReadMarkerGate {
  /// Слать.
  send,

  /// Полная квитанция из окна без фокуса — отложить до `resumed`
  /// (`didChangeAppLifecycleState` дошлёт её сам).
  deferFull,

  /// Не смотрит — не слать.
  blocked,
}

///
/// [humanInput] — человек только что сам действовал в этом чате (отправил,
/// поставил реакцию, нажал кнопку бота — [HumanInputTracker]). Это
/// доказательство внимания сильнее lifecycle: из десктопного окна `inactive`
/// полная квитанция уходит сразу, а не ждёт `resumed` (заявка №60: на Windows
/// окно, в котором человек печатал и отвечал, 6 минут не слало ни одной
/// квитанции). `none` (свёрнуто, скрыто, экран заблокирован) не повышается
/// никогда — иначе квитанция без человека заглушила бы пуш на телефоне
/// (read-grace).
ReadMarkerGate readMarkerGate({
  required ReadableForeground readable,
  required bool isFull,
  bool humanInput = false,
}) {
  switch (readable) {
    case ReadableForeground.none:
      return ReadMarkerGate.blocked;
    case ReadableForeground.partialOnly:
      if (humanInput) return ReadMarkerGate.send;
      return isFull ? ReadMarkerGate.deferFull : ReadMarkerGate.send;
    case ReadableForeground.full:
      return ReadMarkerGate.send;
  }
}

/// Последнее ДЕЙСТВИЕ ЧЕЛОВЕКА в чате: отправка из композера, реакция, кнопка
/// бота. Взводят только UI-точки — НЕ local-echo: эхо порождают и автоповтор
/// неотправленного (FailedSendRetryService), и XL-ключ при открытии чата, и
/// синк с другого устройства, а квитанция «прочитано» без человека перед
/// экраном глушит пуш на телефоне (read-grace). Глобально по roomId, а не в
/// ChatController: реакцию ставит и чип под сообщением, у которого нет
/// доступа к контроллеру.
abstract final class HumanInputTracker {
  /// Сколько действие считается свежим для гейта квитанции.
  static const Duration window = Duration(seconds: 5);

  static final Map<String, DateTime> _last = {};
  static final StreamController<String> _inputs =
      StreamController<String>.broadcast();

  /// roomId каждого нового действия — ChatController шлёт по нему квитанцию
  /// (реакция сама прокрутки и квитанции не вызывает).
  static Stream<String> get onInput => _inputs.stream;

  static void mark(String roomId, {DateTime? now}) {
    _last[roomId] = now ?? DateTime.now();
    _inputs.add(roomId);
  }

  static bool isRecent(
    String roomId, {
    Duration within = window,
    DateTime? now,
  }) {
    final last = _last[roomId];
    if (last == null) return false;
    return (now ?? DateTime.now()).difference(last) <= within;
  }

  @visibleForTesting
  static void reset() => _last.clear();
}

/// Решает, писать ли в лог очередное подавление квитанции после действия
/// человека (заявка №60, фальсификатор гипотезы про lifecycle Windows): не
/// чаще раза на чат за [interval], но каждую СМЕНУ причины — сразу.
class SuppressedReadMarkerLogThrottle {
  SuppressedReadMarkerLogThrottle({
    this.interval = const Duration(seconds: 60),
  });

  final Duration interval;
  String? _lastReason;
  DateTime? _lastAt;

  bool shouldLog(String reason, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final lastAt = _lastAt;
    if (reason == _lastReason &&
        lastAt != null &&
        t.difference(lastAt) < interval) {
      return false;
    }
    _lastReason = reason;
    _lastAt = t;
    return true;
  }
}
