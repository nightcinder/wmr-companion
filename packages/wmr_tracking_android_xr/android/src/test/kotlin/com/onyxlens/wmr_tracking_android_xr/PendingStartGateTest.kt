package com.onyxlens.wmr_tracking_android_xr

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Covers the pending-permission race behind ONY-212 review finding 32c095b9.
 *
 * `stop` and `dispose` call [PendingStartGate.cancel]; Android may still
 * deliver `onRequestPermissionsResult` afterwards, and the plugin only starts a
 * session when [PendingStartGate.resolve] returns that reply.
 */
class PendingStartGateTest {
    private class RecordingReply : StartReply {
        val successes = mutableListOf<Unit>()
        val errors = mutableListOf<Pair<String, String>>()

        override fun success() {
            successes += Unit
        }

        override fun error(code: String, message: String) {
            errors += code to message
        }
    }

    @Test
    fun stopWhilePermissionIsPendingCancelsTheStartAndIgnoresTheLateResult() {
        val gate = PendingStartGate()
        val reply = RecordingReply()
        assertTrue(gate.hold(reply))

        // WmrTrackingAndroidXrPlugin.onMethodCall("stop")
        assertTrue(gate.cancel("unavailable", "Android XR tracking stopped before the start completed"))

        assertFalse(gate.isPending)
        assertNull(gate.resolve(), "a late permission result must not start a session")
        assertEquals(
            listOf("unavailable" to "Android XR tracking stopped before the start completed"),
            reply.errors,
        )
        assertTrue(reply.successes.isEmpty(), "a cancelled start must not resolve successfully")
    }

    @Test
    fun disposeWhilePermissionIsPendingCancelsTheStartAndIgnoresTheLateResult() {
        val gate = PendingStartGate()
        val reply = RecordingReply()
        assertTrue(gate.hold(reply))

        // WmrTrackingAndroidXrPlugin.onMethodCall("dispose")
        assertTrue(
            gate.cancel(
                "unavailable",
                "Android XR tracking source was disposed before the start completed",
            ),
        )

        assertFalse(gate.isPending)
        assertNull(gate.resolve(), "a late permission result must not orphan a session after dispose")
        assertEquals(1, reply.errors.size)
        assertTrue(reply.successes.isEmpty())
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

    @Test
    fun aSecondStartIsRefusedWhileTheFirstIsPending() {
        val gate = PendingStartGate()

        assertTrue(gate.hold(RecordingReply()))
        assertFalse(gate.hold(RecordingReply()))
    }

    @Test
    fun cancelIsIdempotent() {
        val gate = PendingStartGate()
        val reply = RecordingReply()
        gate.hold(reply)

        assertTrue(gate.cancel("unavailable", "first"))
        assertFalse(gate.cancel("unavailable", "second"))
        assertEquals(1, reply.errors.size)
    }
}
