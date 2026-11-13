package com.prodamus.laba.liza.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

// ledger:RL-push-test-sender-and-acks
// AC:RL-push-test-sender-and-acks/9 — `liza_sent_ms` из data FCM → момент отправки в журнале.
class NativePushDiagnosticsTest {
    @Test
    fun sentMsParsesOnlyPositiveNumbers() {
        assertEquals(1_799_999_999_000L, NativePushDiagnostics.sentMs("1799999999000"))
        assertNull(NativePushDiagnostics.sentMs(null))
        assertNull(NativePushDiagnostics.sentMs("soon"))
        assertNull(NativePushDiagnostics.sentMs("-5"))
        assertNull(NativePushDiagnostics.sentMs("0"))
    }
}
