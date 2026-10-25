package com.onyxlens.wmr_tracking_viture

/**
 * The reply seam for one in-flight `start` call.
 *
 * Implemented over `MethodChannel.Result` in the plugin; JVM tests use a
 * recording fake so the permission/lifecycle state machine has no Android
 * dependency.
 */
internal interface StartReply {
    fun success()

    fun error(code: String, message: String)
}

/**
 * Owns the single `start` reply that waits for an Android permission dialog.
 *
 * Android still delivers `onRequestPermissionsResult` after the activity is
 * detached, the Dart source stops or the plugin is disposed. The gate therefore
 * remembers a cancelled start: a late permission result resolves to null and
 * must not start the Unity relay or resolve the stale `start` call.
 */
internal class PendingStartGate {
    private var reply: StartReply? = null

    val isPending: Boolean
        get() = reply != null

    /** Holds [reply] for the permission result; false if one is already held. */
    fun hold(reply: StartReply): Boolean {
        if (this.reply != null) return false
        this.reply = reply
        return true
    }

    /**
     * Takes the held reply for the permission result.
     *
     * Returns null when there is nothing pending, including after [cancel], so
     * the caller can tell a live request from a cancelled one.
     */
    fun resolve(): StartReply? {
        val resolved = reply ?: return null
        reply = null
        return resolved
    }

    /** Fails the held reply with [code]/[message]; idempotent. */
    fun cancel(code: String, message: String): Boolean {
        val cancelled = resolve() ?: return false
        cancelled.error(code, message)
        return true
    }
}
