package com.onyxlens.wmr_tracking_dispatch

import android.app.Activity
import android.content.res.Configuration
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import java.lang.reflect.Proxy

/** The outcome of asking the host to put the shared Unity player on screen. */
data class PlayerHostResult(
    val hosted: Boolean,
    val stage: String,
    val detail: String? = null,
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "playerHosted" to hosted,
        "stage" to stage,
        "detail" to detail,
    )
}

/**
 * Seam that owns the `com.unity3d.player.UnityPlayer` instance and its view.
 *
 * Production uses [ReflectiveUnityPlayerViewHost] so this module compiles
 * without the proprietary Unity export; tests supply a fake.
 */
interface UnityPlayerViewHost {
    /** True when `com.unity3d.player.UnityPlayer` is linked into the build. */
    val isLinked: Boolean

    /** Creates the player in [target] (an [Activity]) and attaches its view full-screen. */
    fun create(target: Any): Boolean

    /** Removes the attached view without destroying the player. */
    fun detach()

    fun pause()

    fun resume()

    fun destroy()

    fun configurationChanged(configuration: Configuration)

    fun windowFocusChanged(focused: Boolean)
}

/** The surface a vendor plugin uses to own the shared player view. */
interface PlayerHost {
    val isHosted: Boolean

    /** Hosts the player in [activity], or reports a typed failure. */
    fun host(activity: Activity?): PlayerHostResult

    /** Gives the display back to Flutter. */
    fun release()
}

/**
 * Owns the one Unity player view a process can put in the foreground activity.
 *
 * The VITURE plugin claims the shared runtime lazily on `start`, so nothing
 * creates a player before a source starts. [host] is idempotent for the same
 * activity, replaces the player when the activity changes, and reports a typed
 * stage instead of throwing. [release] gives the display back to Flutter.
 */
class UnityPlayerHost internal constructor(
    private val viewHost: UnityPlayerViewHost,
) : PlayerHost {

    constructor() : this(ReflectiveUnityPlayerViewHost())

    private var target: Any? = null
    private var hosted = false

    override val isHosted: Boolean
        @Synchronized get() = hosted

    override fun host(activity: Activity?): PlayerHostResult {
        if (activity == null) {
            return PlayerHostResult(
                hosted = false,
                stage = STAGE_UNAVAILABLE,
                detail = "No activity to host the shared Unity player",
            )
        }
        return hostTarget(activity)
    }

    /** Test seam: [UnityPlayerViewHost] receives this unchanged. */
    internal fun hostTarget(newTarget: Any?): PlayerHostResult {
        synchronized(this) {
            if (newTarget == null) {
                return PlayerHostResult(
                    hosted = false,
                    stage = STAGE_UNAVAILABLE,
                    detail = "No activity to host the shared Unity player",
                )
            }
            if (hosted && target === newTarget) {
                return PlayerHostResult(hosted = true, stage = STAGE_PLAYER_HOSTED)
            }
            if (hosted) releaseLocked()
            if (!viewHost.isLinked) {
                return PlayerHostResult(
                    hosted = false,
                    stage = STAGE_UNAVAILABLE,
                    detail = "com.unity3d.player.UnityPlayer is not linked into this build",
                )
            }
            val created = try {
                viewHost.create(newTarget)
            } catch (error: Throwable) {
                return PlayerHostResult(
                    hosted = false,
                    stage = STAGE_HOST_FAILED,
                    detail = error.message ?: error.javaClass.simpleName,
                )
            }
            if (!created) {
                return PlayerHostResult(
                    hosted = false,
                    stage = STAGE_HOST_FAILED,
                    detail = "UnityPlayer did not produce an attachable view",
                )
            }
            target = newTarget
            hosted = true
            return PlayerHostResult(hosted = true, stage = STAGE_PLAYER_HOSTED)
        }
    }

    override fun release() {
        synchronized(this) {
            if (hosted) releaseLocked()
        }
    }

    private fun releaseLocked() {
        hosted = false
        target = null
        runCatching { viewHost.detach() }
    }

    fun onPause() {
        if (hosted) runCatching { viewHost.pause() }
    }

    fun onResume() {
        if (hosted) runCatching { viewHost.resume() }
    }

    fun onConfigurationChanged(configuration: Configuration) {
        if (hosted) runCatching { viewHost.configurationChanged(configuration) }
    }

    fun onWindowFocusChanged(focused: Boolean) {
        if (hosted) runCatching { viewHost.windowFocusChanged(focused) }
    }

    fun onDestroy() {
        synchronized(this) {
            if (hosted) releaseLocked()
            runCatching { viewHost.destroy() }
        }
    }

    companion object {
        const val STAGE_PLAYER_HOSTED = "playerHosted"
        const val STAGE_UNAVAILABLE = "unavailable"
        const val STAGE_HOST_FAILED = "hostFailed"

        /** The process-wide player host the activity and the vendor plugins share. */
        val shared: UnityPlayerHost = UnityPlayerHost()
    }
}

/**
 * Creates and drives the Unity player by reflection so the module compiles
 * with no Unity export on the classpath.
 *
 * Unity 6 moved the embeddable player to
 * `com.unity3d.player.UnityPlayerForActivityOrService`, which takes a
 * `Context` and is not itself a `View`; the older
 * `com.unity3d.player.UnityPlayer` name is kept as a fallback.
 */
internal class ReflectiveUnityPlayerViewHost : UnityPlayerViewHost {
    private var playerClass: Class<*>? = null
    private var linkChecked = false
    private var player: Any? = null
    private var playerView: View? = null

    override val isLinked: Boolean
        get() {
            if (!linkChecked) {
                linkChecked = true
                playerClass = PLAYER_CLASS_NAMES.firstNotNullOfOrNull { name ->
                    try {
                        Class.forName(name)
                    } catch (_: Throwable) {
                        null
                    }
                }
            }
            return playerClass != null
        }

    override fun create(target: Any): Boolean {
        val activity = target as? Activity ?: return false
        // A UnityPlayer may be constructed only once per process, so a stop
        // detaches the view and a later start re-attaches the same one.
        val existing = playerView
        if (existing != null) {
            (existing.parent as? ViewGroup)?.removeView(existing)
            activity.addContentView(existing, fullScreenParams())
            call("resume")
            return true
        }
        val clazz = playerClass ?: return false
        val instance = instantiate(clazz, activity) ?: return false
        val root = viewOf(instance) ?: return false
        activity.addContentView(root, fullScreenParams())
        player = instance
        playerView = root
        return true
    }

    override fun detach() {
        (playerView?.parent as? ViewGroup)?.removeView(playerView)
        // Keep rendering alive but idle; a re-attach resumes it.
        call("pause")
    }

    override fun pause() = call("pause")

    override fun resume() = call("resume")

    override fun destroy() {
        (playerView?.parent as? ViewGroup)?.removeView(playerView)
        call("destroy")
        player = null
        playerView = null
    }

    override fun configurationChanged(configuration: Configuration) =
        call("configurationChanged", configuration)

    override fun windowFocusChanged(focused: Boolean) =
        call("windowFocusChanged", focused)

    private fun fullScreenParams() = FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
    )

    /**
     * Unity 6 takes a `Context` (optionally with a lifecycle listener); the
     * legacy player took the `Activity` directly. Only exact-parameter
     * lookups miss the `Context` overloads, so pick a constructor by
     * assignability instead.
     */
    private fun instantiate(clazz: Class<*>, activity: Activity): Any? {
        val single = clazz.constructors.firstOrNull { constructor ->
            constructor.parameterTypes.size == 1 &&
                constructor.parameterTypes[0].isAssignableFrom(activity.javaClass)
        }
        if (single != null) {
            return runCatching { single.newInstance(activity) }.getOrNull()
        }
        val withListener = clazz.constructors.firstOrNull { constructor ->
            constructor.parameterTypes.size == 2 &&
                constructor.parameterTypes[0].isAssignableFrom(activity.javaClass) &&
                constructor.parameterTypes[1].isInterface
        } ?: return null
        val listenerType = withListener.parameterTypes[1]
        val listener = Proxy.newProxyInstance(
            listenerType.classLoader,
            arrayOf(listenerType),
        ) { _, _, _ -> null }
        return runCatching { withListener.newInstance(activity, listener) }.getOrNull()
    }

    /** Unity 6 exposes `getFrameLayout()`; the legacy player was a `View`. */
    private fun viewOf(instance: Any): View? {
        if (instance is View) return instance
        for (name in VIEW_GETTERS) {
            try {
                val value = instance.javaClass.getMethod(name).invoke(instance)
                if (value is View) return value
            } catch (_: Throwable) {
                // Try the next accessor; a mismatched SDK version must not throw.
            }
        }
        return null
    }

    private fun call(name: String, vararg args: Any?) {
        val instance = player ?: return
        try {
            val method = instance.javaClass.methods.firstOrNull {
                it.name == name && it.parameterTypes.size == args.size
            } ?: return
            method.invoke(instance, *args)
        } catch (_: Throwable) {
            // Lifecycle forwarding is best effort; a missing SDK member must
            // not crash the Flutter activity.
        }
    }

    private companion object {
        const val UNITY_PLAYER_ACTIVITY_SERVICE =
            "com.unity3d.player.UnityPlayerForActivityOrService"
        const val UNITY_PLAYER = "com.unity3d.player.UnityPlayer"

        val PLAYER_CLASS_NAMES = listOf(UNITY_PLAYER_ACTIVITY_SERVICE, UNITY_PLAYER)
        val VIEW_GETTERS = listOf("getFrameLayout", "getView")
    }
}
