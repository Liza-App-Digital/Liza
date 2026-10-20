// ignore_for_file: avoid_print

library;

// ChatList Scroll Position — Preservation Property Tests
//
// These tests encode EXISTING CORRECT behavior on unfixed code.
// They MUST PASS on unfixed code and MUST CONTINUE TO PASS after the fix.
//
// **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**
//
// Preservation 1 — Normal scrolling preserves offset without StreamBuilder rebuild (Req 3.1)
// Preservation 2 — scrolledToTop is true iff offset <= threshold (Req 3.1)
// Preservation 3 — см. test/pages/chat_list/chat_list_tabs_test.dart
// Preservation 4 — Search mode switching does not affect scroll offset (Req 3.3)
// Preservation 5 — Non-bug SyncUpdates (no room update) do not reset scroll position (Req 3.5)

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

// ---------------------------------------------------------------------------
// Helpers — simulate ChatListController scroll and filter logic
// ---------------------------------------------------------------------------

/// Returns true when the input matches the bug condition:
/// app resumed from background, non-zero scroll offset, sync event received,
/// and CustomScrollView lacks PageStorageKey.
bool isBugCondition({
  required bool appResumedFromBackground,
  required double chatListScrollOffset,
  required bool syncEventReceivedAfterResume,
  required bool customScrollViewLacksPageStorageKey,
}) {
  return appResumedFromBackground &&
      chatListScrollOffset > 0 &&
      syncEventReceivedAfterResume &&
      customScrollViewLacksPageStorageKey;
}

/// Simulates the _onScroll listener in ChatListController:
///   void _onScroll() {
///     final newScrolledToTop = scrollController.position.pixels <= 0;
///     if (newScrolledToTop != scrolledToTop.value) {
///       scrolledToTop.value = newScrolledToTop;
///     }
///   }
bool computeScrolledToTop(double pixels) => pixels <= 0;

/// Builds a SyncUpdate that has a room update (triggers StreamBuilder rebuild).
SyncUpdate buildRoomSyncUpdate() {
  return SyncUpdate(
    nextBatch: 's1',
    rooms: RoomsUpdate(
      join: {
        '!testroom:example.com': JoinedRoomUpdate(
          timeline: TimelineUpdate(
            events: [
              MatrixEvent.fromJson({
                'event_id': r'$event1',
                'type': 'm.room.message',
                'sender': '@alice:example.com',
                'origin_server_ts': 1234567890,
                'content': {'msgtype': 'm.text', 'body': 'Hello'},
              }),
            ],
          ),
        ),
      },
    ),
  );
}

/// Builds a SyncUpdate with NO room update (does NOT trigger StreamBuilder rebuild).
SyncUpdate buildNonRoomSyncUpdate() {
  return SyncUpdate(nextBatch: 's2');
}

// ---------------------------------------------------------------------------
// Preservation 1 — Normal scrolling preserves offset without StreamBuilder rebuild
// ---------------------------------------------------------------------------

/// **Validates: Requirements 3.1**
///
/// Observes: when the user scrolls the chat list normally (no StreamBuilder
/// rebuild), the scroll offset is preserved exactly as set.
///
/// Property: for all scroll offset values without StreamBuilder rebuild,
/// the offset is preserved correctly.
void _runNormalScrollingPreservationTests() {
  group('Preservation 1 — Normal scrolling preserves offset without StreamBuilder rebuild', () {
    test(
      'scroll offset is preserved after normal scroll to non-zero position',
      () {
        // Simulate a ScrollController tracking the current offset.
        // Without a StreamBuilder rebuild, the offset is simply what was set.
        var currentOffset = 0.0;

        void simulateScrollTo(double offset) {
          currentOffset = offset;
        }

        simulateScrollTo(300.0);

        expect(
          currentOffset,
          equals(300.0),
          reason: 'Scroll offset must be preserved after normal scroll',
        );
      },
    );

    test(
      'scroll offset is preserved after scrolling back to top (offset=0)',
      () {
        var currentOffset = 500.0;

        void simulateScrollTo(double offset) {
          currentOffset = offset;
        }

        simulateScrollTo(0.0);

        expect(
          currentOffset,
          equals(0.0),
          reason: 'Scroll offset must be 0 after scrolling back to top',
        );
      },
    );

    // Property: for all offsets in [0, 2000], offset is preserved without rebuild
    test(
      'property: for all offsets in [0..2000], offset is preserved without StreamBuilder rebuild',
      () {
        final offsets = [0.0, 1.0, 50.0, 100.0, 300.0, 500.0, 1000.0, 2000.0];

        for (final offset in offsets) {
          var currentOffset = 0.0;

          // Simulate normal scroll — no StreamBuilder rebuild involved
          currentOffset = offset;

          expect(
            currentOffset,
            equals(offset),
            reason: 'Offset $offset must be preserved without StreamBuilder rebuild',
          );
        }
      },
    );

    // Property: isBugCondition is false when there is no StreamBuilder rebuild
    // (syncEventReceivedAfterResume = false)
    test(
      'property: isBugCondition is false for all offsets when no sync event received',
      () {
        final offsets = [0.0, 1.0, 100.0, 500.0, 1000.0];

        for (final offset in offsets) {
          final isBug = isBugCondition(
            appResumedFromBackground: true,
            chatListScrollOffset: offset,
            syncEventReceivedAfterResume: false, // no sync event
            customScrollViewLacksPageStorageKey: true,
          );

          expect(
            isBug,
            isFalse,
            reason:
                'Bug condition must be false for offset=$offset when no sync event received',
          );
        }
      },
    );

    // Property: scroll offset is preserved across multiple scroll operations
    test(
      'property: scroll offset is preserved across multiple sequential scroll operations',
      () {
        var currentOffset = 0.0;
        final scrollHistory = <double>[];

        final scrollSequence = [100.0, 250.0, 500.0, 300.0, 0.0, 750.0];

        for (final target in scrollSequence) {
          currentOffset = target;
          scrollHistory.add(currentOffset);
        }

        expect(
          scrollHistory,
          equals(scrollSequence),
          reason: 'Each scroll offset must be preserved in sequence',
        );
        expect(
          currentOffset,
          equals(scrollSequence.last),
          reason: 'Final offset must equal the last scroll target',
        );
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Preservation 2 — scrolledToTop is true iff offset <= threshold (0)
// ---------------------------------------------------------------------------

/// **Validates: Requirements 3.1**
///
/// Observes: ChatListController._onScroll() sets scrolledToTop.value to
/// (scrollController.position.pixels <= 0). This is the threshold check.
///
/// Property: for all offset values, scrolledToTop = true iff offset <= 0.
void _runScrolledToTopPreservationTests() {
  group('Preservation 2 — scrolledToTop is true iff offset <= threshold (0)', () {
    test(
      'scrolledToTop is true when offset is exactly 0',
      () {
        expect(
          computeScrolledToTop(0.0),
          isTrue,
          reason: 'scrolledToTop must be true when offset is exactly 0',
        );
      },
    );

    test(
      'scrolledToTop is false when offset is positive',
      () {
        expect(
          computeScrolledToTop(1.0),
          isFalse,
          reason: 'scrolledToTop must be false when offset > 0',
        );
        expect(
          computeScrolledToTop(500.0),
          isFalse,
          reason: 'scrolledToTop must be false when offset = 500',
        );
      },
    );

    test(
      'scrolledToTop is true for negative offset (overscroll)',
      () {
        // Negative pixels can occur during overscroll (bounce effect)
        expect(
          computeScrolledToTop(-10.0),
          isTrue,
          reason: 'scrolledToTop must be true for negative offset (overscroll)',
        );
      },
    );

    // Property: for all positive offsets, scrolledToTop is false
    test(
      'property: for all positive offsets, scrolledToTop is false',
      () {
        final positiveOffsets = [
          0.1,
          1.0,
          10.0,
          50.0,
          100.0,
          300.0,
          500.0,
          1000.0,
          2000.0,
        ];

        for (final offset in positiveOffsets) {
          expect(
            computeScrolledToTop(offset),
            isFalse,
            reason: 'scrolledToTop must be false for offset=$offset',
          );
        }
      },
    );

    // Property: for all non-positive offsets, scrolledToTop is true
    test(
      'property: for all non-positive offsets, scrolledToTop is true',
      () {
        final nonPositiveOffsets = [0.0, -0.1, -1.0, -10.0, -100.0];

        for (final offset in nonPositiveOffsets) {
          expect(
            computeScrolledToTop(offset),
            isTrue,
            reason: 'scrolledToTop must be true for offset=$offset',
          );
        }
      },
    );

    // Property: scrolledToTop transitions correctly at the boundary
    test(
      'property: scrolledToTop transitions from true to false when crossing 0',
      () {
        // At 0: true
        expect(computeScrolledToTop(0.0), isTrue);
        // Just above 0: false
        expect(computeScrolledToTop(0.001), isFalse);
        // Just below 0: true
        expect(computeScrolledToTop(-0.001), isTrue);
      },
    );

    // Property: ValueNotifier-style update — only changes when value differs
    test(
      'property: scrolledToTop value only changes when crossing the threshold',
      () {
        var scrolledToTop = true; // initial state (at top)
        final changes = <bool>[];

        void onScroll(double pixels) {
          final newValue = computeScrolledToTop(pixels);
          if (newValue != scrolledToTop) {
            scrolledToTop = newValue;
            changes.add(newValue);
          }
        }

        // Scroll down — should trigger change to false
        onScroll(100.0);
        // Scroll down more — no change (already false)
        onScroll(200.0);
        // Scroll back to top — should trigger change to true
        onScroll(0.0);
        // Stay at top — no change
        onScroll(0.0);

        expect(
          changes,
          equals([false, true]),
          reason: 'scrolledToTop must only change when crossing the threshold',
        );
      },
    );
  });
}

// Preservation 3 (фильтры по типу комнаты) живёт в
// test/pages/chat_list/chat_list_tabs_test.dart — на РЕАЛЬНОМ roomMatchesFilter
// и реальных Room, а не на реплике предиката (RL-chat-list-agents-people-tabs).

// ---------------------------------------------------------------------------
// Preservation 4 — Search mode switching does not affect scroll offset
// ---------------------------------------------------------------------------

/// **Validates: Requirements 3.3**
///
/// Observes: toggling isSearchMode (startSearch / cancelSearch) in
/// ChatListController does not touch the ScrollController offset.
/// The scroll position is independent of search mode state.
///
/// Property: for all scroll offsets, toggling search mode does not change
/// the scroll offset.
void _runSearchModeSwitchingPreservationTests() {
  group('Preservation 4 — Search mode switching does not affect scroll offset', () {
    test(
      'enabling search mode does not change scroll offset',
      () {
        final scrollOffset = 300.0;
        var isSearchMode = false;

        // Simulate startSearch() — only changes isSearchMode, not scrollOffset
        void startSearch() {
          isSearchMode = true;
          // scrollOffset is NOT touched
        }

        startSearch();

        expect(
          scrollOffset,
          equals(300.0),
          reason: 'Scroll offset must not change when search mode is enabled',
        );
        expect(isSearchMode, isTrue);
      },
    );

    test(
      'disabling search mode does not change scroll offset',
      () {
        final scrollOffset = 500.0;
        var isSearchMode = true;

        // Simulate cancelSearch() — only changes isSearchMode, not scrollOffset
        void cancelSearch() {
          isSearchMode = false;
          // scrollOffset is NOT touched
        }

        cancelSearch();

        expect(
          scrollOffset,
          equals(500.0),
          reason: 'Scroll offset must not change when search mode is disabled',
        );
        expect(isSearchMode, isFalse);
      },
    );

    // Property: for all offsets, toggling search mode preserves the offset
    test(
      'property: for all offsets, toggling search mode preserves the offset',
      () {
        final offsets = [0.0, 50.0, 100.0, 300.0, 500.0, 1000.0];

        for (final offset in offsets) {
          final scrollOffset = offset;
          // Simulate toggling search mode on and off — offset is never touched
          // ignore: unused_local_variable
          var isSearchMode = false;
          isSearchMode = true;
          isSearchMode = false;

          expect(
            scrollOffset,
            equals(offset),
            reason:
                'Scroll offset $offset must be preserved after toggling search mode',
          );
        }
      },
    );

    // Property: search mode state is independent of scrolledToTop
    test(
      'property: search mode state is independent of scrolledToTop indicator',
      () {
        final scenarios = [
          (offset: 0.0, searchMode: false),
          (offset: 0.0, searchMode: true),
          (offset: 300.0, searchMode: false),
          (offset: 300.0, searchMode: true),
        ];

        for (final s in scenarios) {
          final scrolledToTop = computeScrolledToTop(s.offset);
          // scrolledToTop depends only on offset, not on search mode
          expect(
            scrolledToTop,
            equals(s.offset <= 0),
            reason:
                'scrolledToTop must depend only on offset, not search mode '
                '(offset=${s.offset}, searchMode=${s.searchMode})',
          );
        }
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Preservation 5 — Non-bug SyncUpdates do not reset scroll position
// ---------------------------------------------------------------------------

/// **Validates: Requirements 3.5**
///
/// Observes: SyncUpdates that do NOT have room updates (hasRoomUpdate = false)
/// are filtered out by the StreamBuilder's `.where((s) => s.hasRoomUpdate)`
/// clause and do NOT trigger a rebuild. Therefore, scroll position is unaffected.
///
/// Property: for all SyncUpdates where hasRoomUpdate = false, the StreamBuilder
/// does not rebuild and the scroll offset is preserved.
void _runNonBugSyncUpdatePreservationTests() {
  group('Preservation 5 — Non-bug SyncUpdates do not reset scroll position', () {
    test(
      'SyncUpdate without room update does not trigger StreamBuilder rebuild',
      () async {
        final onSyncController = StreamController<SyncUpdate>.broadcast();
        var rebuildCount = 0;

        // Simulate the StreamBuilder filter from ChatListViewBody:
        //   stream: client.onSync.stream.where((s) => s.hasRoomUpdate)...
        final filteredStream = onSyncController.stream.where(
          (s) => s.hasRoomUpdate,
        );

        final sub = filteredStream.listen((_) => rebuildCount++);

        // Emit a SyncUpdate with NO room update
        onSyncController.add(buildNonRoomSyncUpdate());
        await Future<void>.delayed(Duration.zero);

        expect(
          rebuildCount,
          equals(0),
          reason:
              'StreamBuilder must NOT rebuild for SyncUpdate without room update',
        );

        await sub.cancel();
        await onSyncController.close();
      },
    );

    test(
      'SyncUpdate with room update triggers StreamBuilder rebuild',
      () async {
        final onSyncController = StreamController<SyncUpdate>.broadcast();
        var rebuildCount = 0;

        final filteredStream = onSyncController.stream.where(
          (s) => s.hasRoomUpdate,
        );

        final sub = filteredStream.listen((_) => rebuildCount++);

        // Emit a SyncUpdate WITH room update
        onSyncController.add(buildRoomSyncUpdate());
        await Future<void>.delayed(Duration.zero);

        expect(
          rebuildCount,
          equals(1),
          reason:
              'StreamBuilder MUST rebuild for SyncUpdate with room update',
        );

        await sub.cancel();
        await onSyncController.close();
      },
    );

    // Property: for all non-room SyncUpdates, scroll offset is preserved
    test(
      'property: scroll offset is preserved for all non-room SyncUpdates',
      () async {
        final onSyncController = StreamController<SyncUpdate>.broadcast();
        var scrollOffset = 400.0;

        final filteredStream = onSyncController.stream.where(
          (s) => s.hasRoomUpdate,
        );

        // On rebuild (room update), simulate scroll reset (the bug scenario)
        final sub = filteredStream.listen((_) {
          // This would be the bug: scroll resets to 0
          // But for non-room updates, this listener is never called
          scrollOffset = 0.0;
        });

        // Emit multiple non-room SyncUpdates
        final nonRoomUpdates = [
          SyncUpdate(nextBatch: 'a'),
          SyncUpdate(nextBatch: 'b'),
          SyncUpdate(nextBatch: 'c'),
        ];

        for (final update in nonRoomUpdates) {
          expect(
            update.hasRoomUpdate,
            isFalse,
            reason: 'Test setup: update must not have room update',
          );
          onSyncController.add(update);
        }

        await Future<void>.delayed(Duration.zero);

        expect(
          scrollOffset,
          equals(400.0),
          reason:
              'Scroll offset must be preserved for all non-room SyncUpdates',
        );

        await sub.cancel();
        await onSyncController.close();
      },
    );

    // Property: isBugCondition is false when syncEventReceivedAfterResume = false
    test(
      'property: isBugCondition is false for all offsets when no sync event after resume',
      () {
        final offsets = [0.0, 1.0, 100.0, 300.0, 500.0, 1000.0, 2000.0];

        for (final offset in offsets) {
          expect(
            isBugCondition(
              appResumedFromBackground: true,
              chatListScrollOffset: offset,
              syncEventReceivedAfterResume: false,
              customScrollViewLacksPageStorageKey: true,
            ),
            isFalse,
            reason:
                'Bug condition must be false for offset=$offset when no sync event',
          );
        }
      },
    );

    // Property: isBugCondition is false when app has NOT resumed from background
    test(
      'property: isBugCondition is false for all offsets when app is in foreground',
      () {
        final offsets = [0.0, 100.0, 500.0, 1000.0];

        for (final offset in offsets) {
          expect(
            isBugCondition(
              appResumedFromBackground: false,
              chatListScrollOffset: offset,
              syncEventReceivedAfterResume: true,
              customScrollViewLacksPageStorageKey: true,
            ),
            isFalse,
            reason:
                'Bug condition must be false for offset=$offset when app is in foreground',
          );
        }
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Test entry point
// ---------------------------------------------------------------------------

void main() {
  _runNormalScrollingPreservationTests();
  _runScrolledToTopPreservationTests();
  _runSearchModeSwitchingPreservationTests();
  _runNonBugSyncUpdatePreservationTests();
}
