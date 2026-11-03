package com.onyxlens.wmr_tracking_android_xr

/**
 * The runtime permissions ARCore for Jetpack XR needs before a [Session] is
 * created.
 *
 * `SCENE_UNDERSTANDING_FINE` stays out: it is the "Precise movement and area
 * data" grant, needed only for fine scene geometry, and this source reads head
 * and hand poses only. `SCENE_UNDERSTANDING_COARSE` still covers the session's
 * environmental understanding.
 */
internal object AndroidXrPermissions {
    const val CAMERA = "android.permission.CAMERA"
    const val SCENE_UNDERSTANDING_COARSE = "android.permission.SCENE_UNDERSTANDING_COARSE"
    const val HAND_TRACKING = "android.permission.HAND_TRACKING"
    const val HEAD_TRACKING = "android.permission.HEAD_TRACKING"

    val required: List<String> =
        listOf(CAMERA, SCENE_UNDERSTANDING_COARSE, HAND_TRACKING, HEAD_TRACKING)
}

/** The reply seam for one in-flight `start` call. */
internal interface StartReply {
    fun success()

    /**
     * Fails the start. [stage] names the boundary that failed, or null when the
     * caller cancelled the start before a boundary was reached.
     */
    fun error(code: String, message: String, stage: String? = null)
}

/** The boundary a typed start error came from. */
internal enum class StartStage(val wire: String) {
    Permissions("permissions"),
    SessionCreate("sessionCreate"),
    SessionConfigure("sessionConfigure"),
    TrackingStart("trackingStart"),
}

/** What the plugin must do next for the start that [AndroidXrStartGate] holds. */
internal sealed interface StartStep {
    /** Ask for exactly these permissions. */
    data class RequestPermissions(val permissions: List<String>) : StartStep

    /** Every permission is granted and the activity is resumed. */
    data object CreateSession : StartStep

    /** Every permission is granted; wait for `ON_RESUME`. */
    data object WaitForResume : StartStep

    /** Nothing to do: the reply was already resolved or the step is not ready. */
    data object Done : StartStep
}

/**
 * Owns the single `start` reply across the permission dialog and the activity
 * resume that follows it.
 *
 * A Jetpack XR session must not be created until every required permission is
 * granted and the activity is resumed; calling `Session.create` while the
 * activity is still paused after the dialog is what crashed the process
 * (ONY-614). Android can deliver the permission result before `ON_RESUME`,
 * after it, or twice, and `stop`/`dispose`/activity detach can cancel the start
 * while the dialog is open. This gate is the state machine for all of those
 * orderings, with no Android dependency so it is covered by JVM tests.
 */
internal class AndroidXrStartGate(
    private val requiredPermissions: List<String> = AndroidXrPermissions.required,
    private val isGranted: (String) -> Boolean,
) {
    private enum class State {
        Idle,
        AwaitingPermissions,
        AwaitingResume,
        Starting,
    }

    private var state = State.Idle
    private var reply: StartReply? = null

    val isPending: Boolean
        get() = state == State.AwaitingPermissions || state == State.AwaitingResume

    /**
     * Begins a start. Returns the first step, or [StartStep.Done] when a reply
     * was failed here (a second concurrent start) or another start is pending.
     */
    fun begin(reply: StartReply, resumed: Boolean): StartStep {
        if (state != State.Idle) {
            reply.error(ERROR_UNAVAILABLE, "An Android XR start is already in progress")
            return StartStep.Done
        }
        this.reply = reply
        val missing = requiredPermissions.filterNot(isGranted)
        if (missing.isNotEmpty()) {
            state = State.AwaitingPermissions
            return StartStep.RequestPermissions(missing)
        }
        return startOrWait(resumed)
    }

    /**
     * Handles `onRequestPermissionsResult`. [permissions] and [grantResults]
     * are Android's arrays; a required permission absent from them falls back
     * to [isGranted], so a partial or empty result cannot start a session.
     */
    fun onPermissionsResult(
        permissions: Array<out String>,
        grantResults: IntArray,
        resumed: Boolean,
    ): StartStep {
        if (state != State.AwaitingPermissions) return StartStep.Done
        val results = permissions.indices.associate { index ->
            permissions[index] to (grantResults.getOrNull(index) == PERMISSION_GRANTED)
        }
        val denied = requiredPermissions.filter { permission ->
            !(results[permission] ?: isGranted(permission))
        }
        if (denied.isNotEmpty()) {
            fail(
                ERROR_PERMISSION_DENIED,
                "Android XR permissions were denied: ${denied.joinToString()}",
                StartStage.Permissions.wire,
            )
            return StartStep.Done
        }
        return startOrWait(resumed)
    }

    /** Handles `ON_RESUME`; a grant that arrived while paused starts here. */
    fun onResumed(): StartStep =
        if (state == State.AwaitingResume) startOrWait(resumed = true) else StartStep.Done

    /** Completes the held start after the session is created and configured. */
    fun succeed() {
        if (state != State.Starting) return
        val pending = reply
        reply = null
        state = State.Idle
        pending?.success()
    }

    /** Fails the held start at [stage]; false when nothing is pending. */
    fun fail(code: String, message: String, stage: String?): Boolean {
        val pending = reply
        reply = null
        state = State.Idle
        if (pending == null) return false
        pending.error(code, message, stage)
        return true
    }

    /** Cancels a start that `stop`, `dispose` or activity detach abandoned. */
    fun cancel(code: String, message: String): Boolean = fail(code, message, null)

    private fun startOrWait(resumed: Boolean): StartStep {
        if (!resumed) {
            state = State.AwaitingResume
            return StartStep.WaitForResume
        }
        state = State.Starting
        return StartStep.CreateSession
    }

    private companion object {
        const val PERMISSION_GRANTED = 0
        const val ERROR_PERMISSION_DENIED = "permissionDenied"
        const val ERROR_UNAVAILABLE = "unavailable"
    }
}
