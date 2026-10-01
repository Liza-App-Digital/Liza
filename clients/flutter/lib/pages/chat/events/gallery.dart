import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/image_bubble.dart';
import 'package:liza/pages/chat/events/upload_overlays.dart';
import 'package:liza/pages/image_viewer/image_viewer.dart';
import 'package:liza/utils/animated_gif.dart';
import 'package:liza/utils/file_description.dart';
import 'package:liza/utils/forwarded_content_builder.dart';
import 'package:liza/utils/resend_failed_media.dart';
import 'package:liza/utils/upload_progress_tracker.dart';
import 'package:liza/utils/video_poster_cache.dart';
import 'package:liza/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:liza/widgets/mxc_image.dart';
import '../../../widgets/blur_hash.dart';

/// Имя кастомного поля альбома в `content` события `m.image`.
const String galleryContentKey = 'com.liza.gallery';

/// Парсеры поля `com.liza.gallery` — чистые функции над `content`-картой,
/// чтобы покрывались юнит-тестами без конструирования `Event`.
///
/// При альбомной отправке (≥2 изображений) `send_file_dialog.dart` кладёт
/// в `content` каждого события:
/// ```jsonc
/// "com.liza.gallery": { "id": "<uuid>", "i": 0, "n": 5, "caption": "..." }
/// ```
/// `caption` присутствует только на событии `i == 0`. Поле namespaced
/// (`com.liza.*`) — federation-safe: чужие клиенты его игнорируют.
/// См. `plans/media-v-format.md` §8.5.
Map<String, Object?>? galleryMapFromContent(Map<String, Object?> content) =>
    content.tryGetMap<String, Object?>(galleryContentKey);

String? galleryIdFromContent(Map<String, Object?> content) =>
    galleryMapFromContent(content)?.tryGet<String>('id');

int galleryIndexFromContent(Map<String, Object?> content) =>
    galleryMapFromContent(content)?.tryGet<int>('i') ?? 0;

int? galleryCountFromContent(Map<String, Object?> content) =>
    galleryMapFromContent(content)?.tryGet<int>('n');

String? galleryCaptionFromContent(Map<String, Object?> content) =>
    galleryMapFromContent(content)?.tryGet<String>('caption');

/// Число колонок сетки альбома для заданного количества изображений.
int galleryColumnsFor(int count) {
  if (count <= 1) return 1;
  if (count <= 4) return 2;
  return 3;
}

/// Grace-окно (мс) для фантом-слотов альбома: пока якорь свежее — держим
/// спиннеры отсутствующих соседей (идёт штатная догрузка по /sync). Старше —
/// показываем факт (легаси-битый форвард, соседей не будет).
const int galleryGraceMs = 60 * 1000;

/// Сколько ячеек рисовать в сетке альбома (чистая функция — рендер
/// `GalleryBubble` покрыт device smoke).
///
/// Заявленное `n` держит спиннеры соседей ТОЛЬКО во время штатной догрузки:
/// ни один член не удалён (`!hasRedacted`), members ещё не все (`membersLen < n`)
/// И якорь свежий (`anchorAgeMs < galleryGraceMs`). Иначе — факт (`membersLen`):
/// легаси-битый форвард (переслан только якорь с исходным `n`, соседи не
/// придут никогда, `originServerTs` старый) НЕ даёт вечных фантом-спиннеров.
int galleryExpectedCount({
  required int membersLen,
  required int? n,
  required bool hasRedacted,
  required int anchorAgeMs,
}) {
  if (n != null &&
      !hasRedacted &&
      membersLen < n &&
      anchorAgeMs < galleryGraceMs) {
    return n;
  }
  return membersLen;
}

/// Собирает ОТПРАВЛЕННЫХ членов альбома [galleryId] из [timeline] в порядке `i`.
///
/// Только `status.isSent` — pending-события ещё без серверного mxc, переслать
/// их нельзя. Dedupe по `eventId` (pending+synced дубль). Порядок — по
/// `galleryIndex` (не по `originServerTs`: члены могут прийти в разном порядке).
List<Event> galleryMembersInTimeline(Timeline timeline, String galleryId) {
  final members = timeline.events
      .where(
        (e) =>
            (e.messageType == MessageTypes.Image ||
                e.messageType == MessageTypes.Video) &&
            !e.redacted &&
            e.status.isSent &&
            galleryIdFromContent(e.content) == galleryId,
      )
      .toList();
  final seen = <String>{};
  members.retainWhere((e) => seen.add(e.eventId));
  members.sort(
    (a, b) => galleryIndexFromContent(a.content)
        .compareTo(galleryIndexFromContent(b.content)),
  );
  return members;
}

/// Строит content'ы ПЕРЕСЫЛКИ для набора [members] одного альбома.
///
/// ⚠️ Корень бага «переслал, но не открывается»: старый форвард копировал
/// только якорь с исходным `n` (напр. 3), а соседей не отправлял → получатель
/// рисовал `n-1` ВЕЧНЫХ фантом-спиннеров. Здесь даём каждому члену НОВЫЙ общий
/// `com.liza.gallery.id`, реиндексируем `i` = 0..N-1 и ставим `n` = ФАКТ числа
/// пересылаемых. caption берётся с исходного `i==0` (или первого, у кого есть)
/// и кладётся на новый `i==0`. Единственный член → обычная одиночная пересылка
/// БЕЗ gallery-поля (иначе получатель попробует склеить со старым id → фантом).
///
/// [members] должны быть уже собраны (напр. [galleryMembersInTimeline]).
Future<List<Map<String, Object?>>> buildForwardedGalleryContents(
  Client client,
  List<Event> members,
) async {
  final sorted = [...members]..sort(
      (a, b) => galleryIndexFromContent(a.content)
          .compareTo(galleryIndexFromContent(b.content)),
    );
  final n = sorted.length;
  if (n <= 1) {
    final content = await buildForwardedContent(sorted.first);
    content.remove(galleryContentKey);
    return [content];
  }
  final newId = client.generateUniqueTransactionId();
  final caption = sorted
      .map((e) => galleryCaptionFromContent(e.content))
      .firstWhere((c) => c != null && c.isNotEmpty, orElse: () => null);
  final result = <Map<String, Object?>>[];
  for (var i = 0; i < n; i++) {
    final content = await buildForwardedContent(sorted[i]);
    content[galleryContentKey] = <String, Object?>{
      'id': newId,
      'i': i,
      'n': n,
      if (i == 0 && caption != null && caption.isNotEmpty) 'caption': caption,
    };
    result.add(content);
  }
  return result;
}

/// Строит content'ы пересылки для НАБОРА событий [events] (одиночный форвард —
/// список из одного; мультивыбор — все выбранные).
///
/// Любой член галереи разворачивается в ВЕСЬ присутствующий в [timeline] альбом
/// (интент «переслать альбом»), альбомы дедуплицируются по `galleryId` (выбор
/// двух членов одного альбома не задваивает). Не-галерейные события —
/// поодиночке через display-событие (`getDisplayEvent` при edit).
///
/// ⚠️ Детект галереи — по ОРИГИНАЛУ `event.content`, НЕ `getDisplayEvent`:
/// SDK при edit якоря подменяет content на `m.new_content` без кастом-полей
/// `com.liza.gallery` → альбом бы «развалился» на одиночку.
Future<List<Map<String, Object?>>> buildForwardedContentsForEvents(
  Client client,
  Timeline timeline,
  List<Event> events,
) async {
  final result = <Map<String, Object?>>[];
  final expandedGalleries = <String>{};
  for (final e in events) {
    final gid = galleryIdFromContent(e.content);
    if (gid != null) {
      if (!expandedGalleries.add(gid)) continue; // альбом уже развёрнут
      final members = galleryMembersInTimeline(timeline, gid);
      result.addAll(
        await buildForwardedGalleryContents(
          client,
          members.isEmpty ? [e] : members,
        ),
      );
    } else {
      result.add(await buildForwardedContent(e.getDisplayEvent(timeline)));
    }
  }
  return result;
}

/// Доступ к полю `com.liza.gallery` события `m.image`.
extension GalleryEvent on Event {
  /// id альбома или `null`, если событие не входит в альбом.
  String? get galleryId => galleryIdFromContent(content);

  /// Порядковый индекс события внутри альбома (0-based).
  int get galleryIndex => galleryIndexFromContent(content);

  /// Ожидаемое число элементов альбома (поле `n`), или `null` если не задано.
  int? get galleryCount => galleryCountFromContent(content);

  /// Подпись альбома (только на событии `i == 0`).
  String? get galleryCaption => galleryCaptionFromContent(content);
}

/// Сводное состояние отправки СВОЕГО альбома.
enum GallerySendState { sent, sending, error }

/// Чистая сводка статуса альбома по его членам (страж
/// `RL-album-send-partial-failure`). Время и галочки альбома раньше брались
/// от якоря i=0 — «✓✓», пока остальные ещё грузились или упали (жалоба
/// 2026-09-25: «непонятно, всё загружено или процесс ещё идёт»).
///
/// - хоть один член упал и серия его уже НЕ досылает → `error` (приоритет);
/// - хоть один отправляется ИЛИ упал, но им владеет идущая серия (дошлёт
///   сама) → `sending`;
/// - иначе → `sent`.
GallerySendState aggregateGallerySendState(
  Iterable<({bool isError, bool isSending, bool ownedBySeries})> members,
) {
  var sending = false;
  for (final m in members) {
    if (m.isError && !m.ownedBySeries) return GallerySendState.error;
    if (m.isSending || m.isError) sending = true;
  }
  return sending ? GallerySendState.sending : GallerySendState.sent;
}

/// Члены альбома [galleryId] в ленте — ВСЕ, включая неотправленные (в
/// отличие от [galleryMembersInTimeline], который берёт только отправленные
/// для пересылки).
List<Event> galleryAllMembersInTimeline(Timeline timeline, String galleryId) {
  final seen = <String>{};
  final members = timeline.events
      .where(
        (e) =>
            (e.messageType == MessageTypes.Image ||
                e.messageType == MessageTypes.Video) &&
            !e.redacted &&
            e.galleryId == galleryId &&
            seen.add(e.eventId),
      )
      .toList();
  members.sort((a, b) => a.galleryIndex.compareTo(b.galleryIndex));
  return members;
}

/// Сводка отправки своего альбома: состояние + упавшие члены, которые
/// пользователь может повторить или удалить.
class GallerySendSummary {
  final GallerySendState state;
  final int total;
  final List<Event> failed;

  const GallerySendSummary({
    required this.state,
    required this.total,
    required this.failed,
  });

  factory GallerySendSummary.of(Timeline timeline, String galleryId) {
    final tracker = UploadProgressTracker.instance;
    final members = galleryAllMembersInTimeline(timeline, galleryId);
    final flags = [
      for (final m in members)
        (
          isError: m.status.isError,
          isSending: m.status.isSending,
          ownedBySeries: tracker.isOwnedBySeries(m.eventId),
        ),
    ];
    return GallerySendSummary(
      state: aggregateGallerySendState(flags),
      total: galleryCountFromContent(
            members.isEmpty ? const {} : members.first.content,
          ) ??
          members.length,
      failed: [
        for (final m in members)
          if (m.status.isError && !tracker.isOwnedBySeries(m.eventId)) m,
      ],
    );
  }
}

enum _AlbumUnsentAction { resend, delete }

/// Меню по тапу на «!» альбома: повторить или удалить неотправленные члены.
/// Как в Telegram — у упавшего альбома действие доступно с самого значка
/// ошибки, а не только из скрытого long-press. Повтор строго ПО ОЧЕРЕДИ:
/// параллельные заливки держали бы в памяти все файлы разом.
Future<void> showAlbumUnsentMenu(
  BuildContext context,
  GallerySendSummary album,
) async {
  final l10n = L10n.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final count = album.failed.length;
  if (count == 0) return;
  final action = await showModalActionPopup<_AlbumUnsentAction>(
    context: context,
    title: l10n.albumNotSentCount(count, album.total),
    cancelLabel: l10n.cancel,
    actions: [
      AdaptiveModalAction(
        label: l10n.resendUnsentMedia(count),
        value: _AlbumUnsentAction.resend,
        icon: const Icon(Icons.refresh),
        isDefaultAction: true,
      ),
      AdaptiveModalAction(
        label: l10n.deleteUnsentMedia(count),
        value: _AlbumUnsentAction.delete,
        icon: const Icon(Icons.delete_outline),
        isDestructive: true,
      ),
    ],
  );
  switch (action) {
    case _AlbumUnsentAction.resend:
      final missing = album.failed.where((e) => e.isUnresendableMissingMedia);
      if (missing.length == count) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.fileNoLongerAvailableToResend)),
        );
        return;
      }
      await FailedMediaResender.resendSequentially(album.failed);
    case _AlbumUnsentAction.delete:
      for (final event in album.failed) {
        await cancelPendingSend(event);
      }
    case null:
      return;
  }
}

/// Сетка-альбом для группы медиа-событий (`m.image` / `m.video`) с общим
/// `com.liza.gallery.id`.
///
/// Виджет получает **anchor**-событие (с минимальным `i`) и сам собирает
/// остальные элементы альбома из `timeline.events`. Не-anchor события в
/// ленте скрыты (`chat_event_list.dart`), поэтому `GalleryBubble`
/// строится один раз на альбом.
class GalleryBubble extends StatelessWidget {
  final Event event;
  final Timeline timeline;

  /// `true` — чат в режиме выделения (long-press уже сработал).
  final bool longPressSelect;

  /// Id выделенных событий — для подсветки отдельных тайлов альбома.
  final Set<String> selectedEventIds;

  /// Toggle-выделение конкретного event'а альбома.
  final void Function(Event)? onSelect;

  /// Плашка времени (Liza-стиль) — в правом нижнем углу сетки альбома.
  final Widget? timeOverlay;

  const GalleryBubble(
    this.event, {
    required this.timeline,
    this.longPressSelect = false,
    this.selectedEventIds = const {},
    this.onSelect,
    this.timeOverlay,
    super.key,
  });

  /// Общая ширина сетки альбома в ленте.
  static const double _gridWidth = 268.0;
  static const double _spacing = 2.0;

  bool _isOwn(Event e) => e.senderId == e.room.client.userID;

  List<Event> _members() {
    final gid = event.galleryId;
    final members = timeline.events
        .where(
          (e) =>
              (e.messageType == MessageTypes.Image ||
                  e.messageType == MessageTypes.Video) &&
              !e.redacted &&
              e.galleryId == gid,
        )
        .toList();
    // Дедупликация по eventId (на случай pending + synced дубля) и
    // сортировка по индексу отправки.
    final seen = <String>{};
    members.retainWhere((e) => seen.add(e.eventId));
    members.sort((a, b) => a.galleryIndex.compareTo(b.galleryIndex));
    return members;
  }

  @override
  Widget build(BuildContext context) {
    final members = _members();
    if (members.isEmpty) {
      // Anchor ещё не доехал в timeline.events — не должно случаться,
      // но не падаем.
      return const SizedBox.shrink();
    }
    final caption = members
        .map((e) => e.galleryCaption)
        .firstWhere((c) => c != null && c.isNotEmpty, orElse: () => null);

    // Ожидаемое число элементов: поле `n` используем только при АКТИВНОЙ
    // загрузке (members ещё не все появились, ни один не удалён, И событие
    // свежее). После удаления (redacted events с тем же gallery id) —
    // фактическое количество, чтобы сетка перестроилась без пустых
    // placeholder-ов.
    //
    // ⚠️ Grace-кап (defensive) против ВЕЧНОГО фантомного спиннера от битого
    // форварда галереи: старый форвард переслал только якорь с `n`=3, а
    // соседей нет и не будет → `members.length < n` истинно навсегда → 2
    // спиннера навечно. Различитель «соседи ещё едут» vs «их не будет» —
    // ВОЗРАСТ якоря (`originServerTs`): соседи альбома идут тем же /sync,
    // доставка — секунды. Свежий якорь (age < grace) → держим спиннеры пока
    // соседи доедут; старый (легаси-форвард, age > grace) → показываем факт.
    final n = event.galleryCount;
    final gid = event.galleryId;
    final hasRedacted = n != null &&
        timeline.events.any(
          (e) =>
              e.galleryId == gid &&
              e.redacted &&
              (e.messageType == MessageTypes.Image ||
                  e.messageType == MessageTypes.Video),
        );
    // 60с — соседи едут секунды (один sync-батч/страница пагинации); ×10-30
    // запас против сетевого лага. Легаси-форвард (age — часы/дни) схлопнется
    // сразу при первом build. Решение вынесено в чистую `galleryExpectedCount`
    // (host-страж `RL-gallery-count-cap-defensive`).
    final anchorAgeMs = DateTime.now().millisecondsSinceEpoch -
        event.originServerTs.millisecondsSinceEpoch;
    final expectedCount = galleryExpectedCount(
      membersLen: members.length,
      n: n,
      hasRedacted: hasRedacted,
      anchorAgeMs: anchorAgeMs,
    );

    final columns = galleryColumnsFor(expectedCount);
    final tileSize = (_gridWidth - (columns - 1) * _spacing) / columns;
    final rows = (expectedCount / columns).ceil();
    final gridHeight = rows * tileSize + (rows - 1) * _spacing;

    // Отступ снизу — чтобы соседние альбомы (особенно подпись предыдущего
    // и сетка следующего) визуально не слипались.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // AnimatedSize: при удалении элементов высота сетки уменьшается
          // плавно, а не рывком — как в Liza. Плашка времени — оверлеем в
          // правом нижнем углу сетки (после сетки в Stack — рисуется поверх).
          Stack(
            children: [
              AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: _gridWidth,
              height: gridHeight,
              child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: expectedCount,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: _spacing,
                crossAxisSpacing: _spacing,
              ),
              itemBuilder: (context, i) {
                if (i >= members.length) {
                  return Material(
                    color: Colors.black12,
                    clipBehavior: Clip.hardEdge,
                    borderRadius: BorderRadius.circular(
                      AppConfig.borderRadius / 3,
                    ),
                    child: const SizedBox.expand(
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator.adaptive(
                            strokeWidth: 2,
                          ),
                        ),
                      ),
                    ),
                  );
                }
                final member = members[i];
                final isVideo =
                    member.messageType == MessageTypes.Video;
                final blurHash =
                    member.infoMap['xyz.amorgan.blurhash'] is String
                    ? member.infoMap['xyz.amorgan.blurhash'] as String
                    : 'LEHV6nWB2yk8pyo0adR*.7kCMdnj';
                final placeholder = BlurHash(
                  blurhash: blurHash,
                  width: tileSize,
                  height: tileSize,
                  fit: BoxFit.cover,
                );
                // Изображение или серверный thumbnail видео.
                Widget tile = MxcImage(
                  event: member,
                  width: tileSize,
                  height: tileSize,
                  fit: BoxFit.cover,
                  isThumbnail: true,
                  placeholder: (context) => placeholder,
                );
                // Плитка альбома GIF не анимируется (как в Telegram) —
                // только бейдж; тап открывает вьювер, где GIF играет.
                if (isGifImageEvent(member)) {
                  tile = Stack(
                    fit: StackFit.expand,
                    children: [
                      tile,
                      const Positioned(top: 4, left: 4, child: GifBadge()),
                    ],
                  );
                }
                if (isVideo) {
                  final durationMs = member.content
                      .tryGetMap<String, Object?>('info')
                      ?.tryGet<int>('duration');
                  final dur = durationMs == null
                      ? null
                      : Duration(milliseconds: durationMs);
                  tile = Stack(
                    fit: StackFit.expand,
                    children: [
                      // Отправка идёт/упала — кадр локальный (память SDK или
                      // дисковый кэш постера по txid): серверного ещё нет, а
                      // превью sending-видео через MxcImage давало байты MP4.
                      // Отправлено — серверный thumbnail, иначе BlurHash.
                      if (!member.status.isSent)
                        PendingVideoPoster(
                          event: member,
                          placeholder: placeholder,
                        )
                      else if (member.hasThumbnail)
                        tile
                      else
                        placeholder,
                      if (member.status.isSent)
                        const Center(
                          child: Icon(
                            Icons.play_circle_outline,
                            color: Colors.white70,
                            size: 32,
                          ),
                        ),
                      if (dur != null)
                        Positioned(
                          bottom: 4,
                          left: 4,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              child: Text(
                                '${dur.inMinutes.toString().padLeft(2, '0')}:'
                                '${(dur.inSeconds % 60).toString().padLeft(2, '0')}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                }
                final isSelected =
                    selectedEventIds.contains(member.eventId);
                return Material(
                  color: Colors.black,
                  clipBehavior: Clip.hardEdge,
                  borderRadius: BorderRadius.circular(
                    AppConfig.borderRadius / 3,
                  ),
                  child: InkWell(
                    onTap: longPressSelect
                        ? () => onSelect?.call(member)
                        : () => showDialog(
                              context: context,
                              builder: (_) => ImageViewer(
                                member,
                                timeline: timeline,
                                outerContext: context,
                              ),
                            ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        tile,
                        // Статус отправки ЭТОГО члена: прогресс / «Ожидание
                        // сети» / ↻. Раньше плитка статуса не несла вовсе —
                        // упавшее видео выглядело отправленным (2026-09-25).
                        if (_isOwn(member))
                          Positioned.fill(
                            child: IgnorePointer(
                              ignoring: longPressSelect,
                              child: UploadStatusOverlay(
                                event: member,
                                compact: true,
                                fallback: const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        if (longPressSelect)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Icon(
                              isSelected
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              color: isSelected
                                  ? Colors.blue
                                  : Colors.white70,
                              size: 22,
                              shadows: const [
                                Shadow(blurRadius: 4, color: Colors.black54),
                              ],
                            ),
                          ),
                        if (isSelected)
                          Container(
                            color: Colors.blue.withAlpha(50),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          ),
              if (timeOverlay != null)
                Positioned(bottom: 6, right: 6, child: timeOverlay!),
            ],
          ),
          // Подпись — прямо под сеткой, вплотную, выровнена по левому краю
          // изображений (как в Liza). Цвет — обычный текст на фоне
          // чата: у альбома нет фона-bubble (media-v-format.md §8.6).
          if (caption != null && caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6.0, bottom: 2.0),
              child: SizedBox(
                width: _gridWidth,
                child: Text(
                  caption,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Кадр видео-члена альбома, пока отправка идёт или упала: серверного
/// thumbnail ещё нет. Сначала — постер в памяти SDK
/// (`sendingFileThumbnails`, есть с момента `sendFileEvent` и живёт у
/// упавшего), затем — дисковый кэш постера по txid (`VideoPosterCache`,
/// пишется на подготовке, до передачи SDK), иначе [placeholder].
class PendingVideoPoster extends StatefulWidget {
  final Event event;
  final Widget placeholder;

  const PendingVideoPoster({
    required this.event,
    required this.placeholder,
    super.key,
  });

  @override
  State<PendingVideoPoster> createState() => _PendingVideoPosterState();
}

class _PendingVideoPosterState extends State<PendingVideoPoster> {
  Future<File?>? _cached;
  String? _cachedFor;

  Future<File?> _diskPoster() {
    final id = widget.event.eventId;
    if (_cachedFor != id) {
      _cachedFor = id;
      _cached = VideoPosterCache.instance.getCached(widget.event);
    }
    return _cached!;
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final inMemory = event.room.sendingFileThumbnails[event.eventId];
    if (inMemory != null) {
      return Image.memory(
        inMemory.bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, _, _) => widget.placeholder,
      );
    }
    if (kIsWeb) return widget.placeholder;
    return FutureBuilder<File?>(
      future: _diskPoster(),
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) return widget.placeholder;
        return Image.file(
          file,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, _, _) => widget.placeholder,
        );
      },
    );
  }
}
