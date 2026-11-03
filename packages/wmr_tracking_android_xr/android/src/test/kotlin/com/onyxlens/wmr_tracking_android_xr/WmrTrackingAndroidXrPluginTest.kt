package com.onyxlens.wmr_tracking_android_xr

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Covers the crash boundaries tightened by ONY-669: the capability hand probe,
 * building the session config, and a collector that faults while the `start`
 * reply is still held.
 */
class WmrTrackingAndroidXrPluginTest {
    private data class Failure(val code: String, val message: String, val stage: String?)

    private class RecordingReply : StartReply {
        val successes = mutableListOf<Unit>()
        val errors = mutableListOf<Failure>()

        override fun success() {
            successes += Unit
        }

        override fun error(code: String, message: String, stage: String?) {
            errors += Failure(code, message, stage)
        }
    }

    @Test
    fun aHandProbeFaultIsReportedAsUnsupported() {
        val reason = WmrTrackingAndroidXrPlugin.handTrackingReason {
            throw IllegalStateException("runtime probe exploded")
        }

        val text = requireNotNull(reason)
        assertTrue(text.contains("hand tracking check failed"))
        assertTrue(text.contains("runtime probe exploded"))
    }

    @Test
    fun anUnsupportedHandProbeKeepsTheModeReason() {
        assertEquals(
            "HandTrackingMode.BOTH is unsupported",
            WmrTrackingAndroidXrPlugin.handTrackingReason { false },
        )
    }

    @Test
    fun aSupportedHandProbeHasNoReason() {
        assertNull(WmrTrackingAndroidXrPlugin.handTrackingReason { true })
    }

    @Test
    fun aConfigBuilderFaultIsReportedAtSessionConfigure() {
        val failure = WmrTrackingAndroidXrPlugin.configureFailure(
            IllegalStateException("builder exploded"),
        )

        assertEquals("unavailable", failure.code)
        assertEquals(StartStage.SessionConfigure, failure.stage)
        assertEquals("Session.configure failed: builder exploded", failure.message)
    }

    @Test
    fun anIllegalConfigureArgumentStaysUnsupported() {
        val failure = WmrTrackingAndroidXrPlugin.configureFailure(
            IllegalArgumentException("bad tracking mode"),
        )

        assertEquals("unsupported", failure.code)
        assertEquals(StartStage.SessionConfigure, failure.stage)
    }

    @Test
    fun aCollectorFaultIsReportedAtTrackingStart() {
        val failure = WmrTrackingAndroidXrPlugin.trackingFailure(
            RuntimeException("collector exploded"),
        )

        assertEquals("unavailable", failure.code)
        assertEquals(StartStage.TrackingStart, failure.stage)
        assertEquals("Android XR tracking failed: collector exploded", failure.message)
    }

    @Test
    fun aFaultWhileTheStartIsHeldNamesTrackingStartInsteadOfCancel() {
        val granted = AndroidXrPermissions.required.toSet()
        val gate = AndroidXrStartGate { it in granted }
        val reply = RecordingReply()
        assertEquals(StartStep.CreateSession, gate.begin(reply, resumed = true))

        val failure = WmrTrackingAndroidXrPlugin.trackingFailure(
            RuntimeException("first collect failed"),
        )
        assertTrue(gate.fail(failure.code, failure.message, failure.stage.wire))

        val error = reply.errors.single()
        assertEquals("trackingStart", error.stage)
        assertEquals("unavailable", error.code)
        assertTrue(reply.successes.isEmpty())
    }

    @Test
    fun aThrowableWithoutAMessageFallsBackToItsClassName() {
        assertEquals(
            "IllegalStateException",
            WmrTrackingAndroidXrPlugin.describe(IllegalStateException()),
        )
    }
}
