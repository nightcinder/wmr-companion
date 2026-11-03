package com.onyxlens.wmr_tracking_viture

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class PendingStartGateTest {
    private class RecordingReply : StartReply {
        val successes = mutableListOf<Map<String, Any?>>()
        val errors = mutableListOf<Pair<String, String>>()
        val stages = mutableListOf<String?>()

        override fun success(report: Map<String, Any?>) {
            successes += report
        }

        override fun error(code: String, message: String, stage: String?) {
            errors += code to message
            stages += stage
        }
    }

    @Test
    fun stopWhilePermissionIsPendingCancelsTheStartAndIgnoresTheLateResult() {
        val gate = PendingStartGate()
        val reply = RecordingReply()
        assertTrue(gate.hold(reply))

        assertTrue(
            gate.cancel(
                "unavailable",
                "VITURE tracking stopped before the start completed",
            ),
        )

        assertFalse(gate.isPending)
        assertNull(gate.resolve(), "a late permission result must not start the Unity relay")
        assertEquals(
            listOf("unavailable" to "VITURE tracking stopped before the start completed"),
            reply.errors,
        )
        assertTrue(reply.successes.isEmpty())
    }

    @Test
    fun disposeWhilePermissionIsPendingCancelsTheStartAndIgnoresTheLateResult() {
        val gate = PendingStartGate()
        val reply = RecordingReply()
        assertTrue(gate.hold(reply))

        assertTrue(
            gate.cancel(
                "unavailable",
                "VITURE tracking source was disposed before the start completed",
            ),
        )

        assertFalse(gate.isPending)
        assertNull(gate.resolve())
        assertEquals(1, reply.errors.size)
        assertTrue(reply.successes.isEmpty())
    }

    @Test
    fun aSecondHoldIsRefusedSoTheFirstStartKeepsItsReply() {
        val gate = PendingStartGate()
        val first = RecordingReply()
        val second = RecordingReply()
        assertTrue(gate.hold(first))

        assertFalse(gate.hold(second))
        assertSame(first, gate.resolve())
        assertTrue(second.errors.isEmpty())
    }

    @Test
    fun aResolvedPermissionRequestKeepsTheOriginalReply() {
        val gate = PendingStartGate()
        val reply = RecordingReply()
        assertTrue(gate.hold(reply))

        assertSame(reply, gate.resolve())
        assertNull(gate.resolve())
        assertFalse(gate.cancel("unavailable", "late stop"))
        assertTrue(reply.errors.isEmpty())
    }
}
