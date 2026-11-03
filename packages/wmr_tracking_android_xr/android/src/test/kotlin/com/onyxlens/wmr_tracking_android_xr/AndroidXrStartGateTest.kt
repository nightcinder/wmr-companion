package com.onyxlens.wmr_tracking_android_xr

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Covers the permission/resume state machine behind ONY-614.
 *
 * The plugin must request CAMERA, SCENE_UNDERSTANDING_COARSE, HAND_TRACKING and
 * HEAD_TRACKING, and only create a Jetpack XR session once every grant is in
 * and the activity is resumed. Android may deliver the permission result before
 * or after `ON_RESUME`, more than once, or not at all when `stop`/`dispose`
 * cancels the start.
 */
class AndroidXrStartGateTest {
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

    private val granted = mutableSetOf<String>()
    private val requested = AndroidXrPermissions.required

    private fun gate() = AndroidXrStartGate(requested) { it in granted }

    private fun grantsAll() {
        granted += requested
    }

    @Test
    fun theRequiredSetIsCameraCoarseSceneHandsAndHead() {
        assertEquals(
            listOf(
                "android.permission.CAMERA",
                "android.permission.SCENE_UNDERSTANDING_COARSE",
                "android.permission.HAND_TRACKING",
                "android.permission.HEAD_TRACKING",
            ),
            AndroidXrPermissions.required,
        )
    }

    @Test
    fun anExistingGrantStartsImmediately() {
        grantsAll()
        val gate = gate()
        val reply = RecordingReply()

        assertEquals(StartStep.CreateSession, gate.begin(reply, resumed = true))

        gate.succeed()
        assertEquals(1, reply.successes.size)
        assertTrue(reply.errors.isEmpty())
        assertFalse(gate.isPending)
    }

    @Test
    fun onlyTheMissingPermissionsAreRequested() {
        granted += "android.permission.HAND_TRACKING"
        val gate = gate()

        val step = gate.begin(RecordingReply(), resumed = true)

        assertEquals(
            StartStep.RequestPermissions(
                listOf(
                    "android.permission.CAMERA",
                    "android.permission.SCENE_UNDERSTANDING_COARSE",
                    "android.permission.HEAD_TRACKING",
                ),
            ),
            step,
        )
    }

    @Test
    fun aFullGrantWaitsForResumeWhenTheActivityIsPaused() {
        val gate = gate()
        val reply = RecordingReply()
        val step = gate.begin(reply, resumed = true) as StartStep.RequestPermissions
        grantsAll()

        assertEquals(
            StartStep.WaitForResume,
            gate.onPermissionsResult(step.permissions.toTypedArray(), IntArray(step.permissions.size), resumed = false),
        )
        assertTrue(gate.isPending)

        assertEquals(StartStep.CreateSession, gate.onResumed())
        gate.succeed()
        assertEquals(1, reply.successes.size)
    }

    @Test
    fun everyPermissionAlreadyGrantedButPausedWaitsForResume() {
        grantsAll()
        val gate = gate()
        val reply = RecordingReply()

        assertEquals(StartStep.WaitForResume, gate.begin(reply, resumed = false))

        assertEquals(StartStep.CreateSession, gate.onResumed())
        gate.succeed()
        assertEquals(1, reply.successes.size)
    }

    @Test
    fun aDenialIsPermissionDeniedAtThePermissionStageAndNeverCreatesASession() {
        val gate = gate()
        val reply = RecordingReply()
        val step = gate.begin(reply, resumed = true) as StartStep.RequestPermissions

        assertEquals(
            StartStep.Done,
            gate.onPermissionsResult(
                step.permissions.toTypedArray(),
                IntArray(step.permissions.size) { -1 },
                resumed = true,
            ),
        )

        assertEquals(1, reply.errors.size)
        assertEquals("permissionDenied", reply.errors.single().code)
        assertEquals(StartStage.Permissions.wire, reply.errors.single().stage)
        assertTrue(reply.successes.isEmpty())
        assertTrue(reply.errors.single().message.contains("SCENE_UNDERSTANDING_COARSE"))
        assertEquals(StartStep.Done, gate.onResumed(), "a late resume must not start a denied session")
    }

    @Test
    fun aPartialGrantIsPermissionDeniedForTheDeniedPermissions() {
        granted += "android.permission.HAND_TRACKING"
        val gate = gate()
        val reply = RecordingReply()
        val step = gate.begin(reply, resumed = true) as StartStep.RequestPermissions
        granted += step.permissions

        assertEquals(
            StartStep.Done,
            gate.onPermissionsResult(
                step.permissions.toTypedArray(),
                intArrayOf(0, -1, 0),
                resumed = true,
            ),
        )

        assertEquals(1, reply.errors.size)
        assertEquals("permissionDenied", reply.errors.single().code)
        assertTrue(reply.errors.single().message.contains("SCENE_UNDERSTANDING_COARSE"))
        assertTrue(reply.successes.isEmpty())
    }

    @Test
    fun aResultThatOmitsAGrantFallsBackToThePermissionCheck() {
        val gate = gate()
        val reply = RecordingReply()
        gate.begin(reply, resumed = true)

        assertEquals(
            StartStep.Done,
            gate.onPermissionsResult(emptyArray(), IntArray(0), resumed = true),
        )

        assertEquals("permissionDenied", reply.errors.single().code)
        assertTrue(reply.successes.isEmpty())
    }

    @Test
    fun aResultBeforeResumeStartsExactlyOnceOnResume() {
        val gate = gate()
        val reply = RecordingReply()
        val step = gate.begin(reply, resumed = true) as StartStep.RequestPermissions
        grantsAll()

        assertEquals(
            StartStep.WaitForResume,
            gate.onPermissionsResult(step.permissions.toTypedArray(), IntArray(step.permissions.size), resumed = false),
        )
        assertEquals(StartStep.CreateSession, gate.onResumed())
        assertEquals(StartStep.Done, gate.onResumed(), "a duplicate resume must not start a second session")
        assertEquals(StartStep.Done, gate.onResumed())

        gate.succeed()
        assertEquals(1, reply.successes.size)
    }

    @Test
    fun aResumeBeforeTheResultWaitsForTheGrant() {
        val gate = gate()
        val reply = RecordingReply()
        val step = gate.begin(reply, resumed = true) as StartStep.RequestPermissions
        grantsAll()

        assertEquals(StartStep.Done, gate.onResumed(), "resuming before the result has nothing to start")

        assertEquals(
            StartStep.CreateSession,
            gate.onPermissionsResult(step.permissions.toTypedArray(), IntArray(step.permissions.size), resumed = true),
        )
        gate.succeed()
        assertEquals(1, reply.successes.size)
    }

    @Test
    fun aDuplicatePermissionResultCannotOpenASecondSession() {
        val gate = gate()
        val reply = RecordingReply()
        val step = gate.begin(reply, resumed = true) as StartStep.RequestPermissions

        assertEquals(
            StartStep.CreateSession,
            gate.onPermissionsResult(step.permissions.toTypedArray(), IntArray(step.permissions.size), resumed = true),
        )
        assertEquals(
            StartStep.Done,
            gate.onPermissionsResult(step.permissions.toTypedArray(), IntArray(step.permissions.size), resumed = true),
        )

        gate.succeed()
        assertEquals(1, reply.successes.size)
    }

    @Test
    fun stopCancelsThePendingStartAndIgnoresTheLateGrant() {
        val gate = gate()
        val reply = RecordingReply()
        val step = gate.begin(reply, resumed = true) as StartStep.RequestPermissions

        assertTrue(gate.cancel("unavailable", "Android XR tracking stopped before the start completed"))
        assertFalse(gate.isPending)
        assertTrue(reply.successes.isEmpty())
        assertEquals(1, reply.errors.size)
        assertNull(reply.errors.single().stage)

        grantsAll()
        assertEquals(
            StartStep.Done,
            gate.onPermissionsResult(step.permissions.toTypedArray(), IntArray(step.permissions.size), resumed = true),
            "a grant that arrives after stop must not open a session",
        )
        assertEquals(StartStep.Done, gate.onResumed())
        assertEquals(1, reply.errors.size)
    }

    @Test
    fun aStartAfterACancelledStartIsAllowed() {
        val gate = gate()
        gate.begin(RecordingReply(), resumed = true)
        gate.cancel("unavailable", "stopped")

        grantsAll()
        val second = RecordingReply()
        assertEquals(StartStep.CreateSession, gate.begin(second, resumed = true))
        gate.succeed()
        assertEquals(1, second.successes.size)
    }

    @Test
    fun aSecondStartIsRefusedWhileTheFirstIsPending() {
        val gate = gate()
        assertTrue(gate.begin(RecordingReply(), resumed = true) is StartStep.RequestPermissions)
        val second = RecordingReply()

        assertEquals(StartStep.Done, gate.begin(second, resumed = true))

        assertEquals(1, second.errors.size)
        assertEquals("unavailable", second.errors.single().code)
        assertTrue(gate.isPending)
    }

    @Test
    fun aSessionStageIsPassedThroughToTheReply() {
        grantsAll()
        val gate = gate()
        val reply = RecordingReply()
        gate.begin(reply, resumed = true)

        assertTrue(gate.fail("unavailable", "Session.create failed", StartStage.SessionCreate.wire))

        assertEquals("unavailable", reply.errors.single().code)
        assertEquals("sessionCreate", reply.errors.single().stage)
        assertFalse(gate.isPending)
    }
}
