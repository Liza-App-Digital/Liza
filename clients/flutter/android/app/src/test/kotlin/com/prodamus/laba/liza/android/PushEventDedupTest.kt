package com.prodamus.laba.liza.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// ledger:RL-push-read-banner-sweep
// AC:RL-push-read-banner-sweep/10 — повтор event_id не будит Dart (второго звука нет).
class PushEventDedupTest {
    @Test
    fun repeatIsRejectedAndWindowUnchanged() {
        val (first, window) = PushEventDedup.admit(emptyList(), "a")
        assertTrue(first)
        assertEquals(listOf("a"), window)
        val (again, same) = PushEventDedup.admit(window, "a")
        assertFalse(again)
        assertEquals(window, same)
    }

    @Test
    fun windowKeepsLast200AndForgetsOldest() {
        var window = emptyList<String>()
        for (i in 0 until PushEventDedup.CAPACITY + 1) {
            window = PushEventDedup.admit(window, "e$i").second
        }
        assertEquals(PushEventDedup.CAPACITY, window.size)
        assertEquals("e${PushEventDedup.CAPACITY}", window.last())
        // Самое старое вытеснено — его повтор снова «первый» (лишний звук
        // лучше потерянного уведомления), свежее по-прежнему глушится.
        assertTrue(PushEventDedup.admit(window, "e0").first)
        assertFalse(PushEventDedup.admit(window, "e1").first)
        assertFalse(PushEventDedup.admit(window, "e200").first)
    }

    @Test
    fun eventHashMatchesSygnalAndDartFormat() {
        // sha256("$e1")[:32] hex — тот же ключ, что event_hash в логах Sygnal
        // (`_push_outcomes.py`) и в блоке acks (RL-push-device-acks AC-1).
        assertEquals("89750ae9d56358c16ed36cba9429b601", NativePushDiagnostics.eventHash("\$e1"))
    }
}
