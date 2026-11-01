package com.onyxlens.wmr_tracking_dispatch

/** How a vendor's claim on the shared Unity runtime was resolved. */
enum class UnityClaimState(val wireName: String) {
    /** This vendor was the first claim and owns the runtime. */
    OWNER("owner"),

    /** Another vendor already owns it; this vendor reuses the same runtime. */
    REUSED("reused"),

    /** No Unity runtime is linked, so nothing can start. */
    UNAVAILABLE("unavailable"),
}

/** The latest stage and display report the hosted player sent for a vendor. */
data class UnityStageReport(val stage: String, val stereoMode: String?)

/**
 * Failure boundaries reported in a start error's `details.stage`.
 *
 * Both vendor plugins share these names so Dart can tell "player never hosted"
 * from "loader never initialised" from "start was detached".
 */
object TrackingStartStage {
    const val DISPOSED = "disposed"
    const val PENDING = "pending"
    const val LINK = "link"
    const val ACTIVITY = "activity"
    const val PERMISSION = "permission"
    const val CLAIM = "claim"
    const val MODEL = "model"
    const val COMMAND = "command"
    const val RUNTIME = "runtime"
    const val DETACH = "detach"
    const val START_FAILED = "startFailed"
}

/** The result of [SharedUnityRuntime.claim]. */
data class UnityClaim(val state: UnityClaimState, val owner: GlassesVendor?) {
    val granted: Boolean = state != UnityClaimState.UNAVAILABLE

    fun toMap(): Map<String, Any?> = linkedMapOf(
        "state" to state.wireName,
        "owner" to owner?.wireName,
    )
}

/**
 * Owns the one UnityPlayer a process can host and routes its callbacks to the
 * plugin registered for a vendor.
 *
 * The first VITURE or XREAL plugin to call [claim] becomes the owner and marks
 * the runtime created; [createPlayer] is the injected creation seam. Both
 * plugins host a [PlayerHost] and only claim after it reports an attached
 * player, so ownership always means a real view exists. The other plugin
 * reuses the same runtime ([UnityClaimState.REUSED]) and never creates a
 * second player. Frames, errors
 * addressed by vendor, with the owner as a fallback for untagged callbacks.
 * Android XR does not use Unity and never claims.
 */
class SharedUnityRuntime(
    private val createPlayer: () -> Boolean = { false },
) {
    /** Implemented by each vendor plugin to receive the shared callbacks. */
    interface Handler {
        fun onFrame(frameJson: String)

        fun onError(code: String, message: String)

        fun onGlassesModel(modelName: String?)

        /** Optional: stage/display reports from the hosted scene. */
        fun onStage(stage: String, stereoMode: String?) = Unit
    }

    private var created = false
    private var owner: GlassesVendor? = null
    private var hosted = false
    private val handlers = LinkedHashMap<GlassesVendor, Handler>()
    private val glassesModels = mutableMapOf<GlassesVendor, String?>()
    private val stages = mutableMapOf<GlassesVendor, UnityStageReport>()

    val ownerVendor: GlassesVendor?
        @Synchronized get() = owner

    /**
     * [create] runs once, on the first claim, when the caller needs to own the
     * real player creation (the VITURE plugin passes its [PlayerHost] result).
     * Without a factory the runtime fails closed instead of pretending a
     * player exists. A failed creation is retried on the next claim instead of
     * disabling the runtime for the rest of the process.
     */
    @Synchronized
    fun claim(vendor: GlassesVendor, create: (() -> Boolean)? = null): UnityClaim {
        if (vendor == GlassesVendor.NONE) {
            return UnityClaim(UnityClaimState.UNAVAILABLE, null)
        }
        if (!created) {
            created = (create ?: createPlayer)()
        }
        if (!created) {
            return UnityClaim(UnityClaimState.UNAVAILABLE, null)
        }
        val current = owner
        if (current == null) {
            owner = vendor
            return UnityClaim(UnityClaimState.OWNER, vendor)
        }
        return if (current == vendor) {
            UnityClaim(UnityClaimState.OWNER, vendor)
        } else {
            UnityClaim(UnityClaimState.REUSED, current)
        }
    }

    /**
     * Drops ownership after [vendor] stops. The runtime stays created for the
     * process; a later claim by another vendor reuses it.
     */
    @Synchronized
    fun release(vendor: GlassesVendor) {
        if (owner == vendor) owner = null
    }

    @Synchronized
    fun register(vendor: GlassesVendor, handler: Handler) {
        handlers[vendor] = handler
    }

    @Synchronized
    fun unregister(vendor: GlassesVendor, handler: Handler) {
        if (handlers[vendor] === handler) handlers.remove(vendor)
    }

    fun dispatchFrame(vendor: GlassesVendor, frameJson: String) {
        handlerFor(vendor)?.onFrame(frameJson)
    }

    fun dispatchError(vendor: GlassesVendor, code: String, message: String) {
        handlerFor(vendor)?.onError(code, message)
    }

    fun dispatchGlassesModel(vendor: GlassesVendor, modelName: String?) {
        synchronized(this) { glassesModels[vendor] = modelName }
        handlerFor(vendor)?.onGlassesModel(modelName)
    }

    @Synchronized
    fun glassesModel(vendor: GlassesVendor): String? = glassesModels[vendor]

    /**
     * Records a stage/display report from the hosted scene. The stage is kept
     * per vendor so `capabilities` can answer `playerHosted`, `stereoMode` and
     * the last reached startup stage after the fact.
     */
    fun dispatchStage(vendor: GlassesVendor, stage: String, stereoMode: String?) {
        if (vendor == GlassesVendor.NONE || stage.isBlank()) return
        synchronized(this) {
            stages[vendor] = UnityStageReport(stage, stereoMode)
            if (stage == UnityPlayerHost.STAGE_PLAYER_HOSTED) hosted = true
        }
        handlerFor(vendor)?.onStage(stage, stereoMode)
    }

    @Synchronized
    fun stage(vendor: GlassesVendor): UnityStageReport? = stages[vendor]

    /**
     * Whether the shared scene has ever reported [UnityPlayerHost.STAGE_PLAYER_HOSTED].
     *
     * Unlike [stage] this survives [clearStage]: the player is constructed once
     * per process, so a later start only re-attaches and resumes an already
     * initialised scene. Vendor plugins use it to tell a cold start, where
     * `UnitySendMessage` must wait, from a warm one, where it is safe (ONY-776).
     */
    @Synchronized
    fun hasHostedScene(): Boolean = hosted

    /**
     * Forgets that the scene was hosted after its player is destroyed. The
     * next start may construct a new player, so it must wait for `playerHosted`
     * again instead of sending `UnitySendMessage` during init (ONY-776).
     */
    @Synchronized
    fun clearHostedScene() {
        hosted = false
    }

    /**
     * Routes a stage report that came from the one shared stereo scene to the
     * vendor that currently owns the runtime.
     *
     * Both vendors load the same scene, and its rig still reports through the
     * VITURE plugin's static entry point (the XREAL scene points at the XREAL
     * class in ONY-707). Attributing the report to the owner keeps
     * `playerHosted`, `stereoMode` and the start replay correct whichever
     * vendor is active. Before any claim the report belongs to VITURE, which
     * is the only vendor that ever hosted the shared scene before XREAL
     * hosting existed.
     */
    fun dispatchHostStage(stage: String, stereoMode: String?) {
        val vendor = synchronized(this) { owner } ?: GlassesVendor.VITURE
        dispatchStage(vendor, stage, stereoMode)
    }

    /** Drops the stage a previous session reported so a new one starts clean. */
    @Synchronized
    fun clearStage(vendor: GlassesVendor) {
        if (vendor == GlassesVendor.NONE) return
        stages.remove(vendor)
    }

    @Synchronized
    private fun handlerFor(vendor: GlassesVendor): Handler? =
        if (vendor == GlassesVendor.NONE) {
            owner?.let { handlers[it] }
        } else {
            handlers[vendor]
        }

    companion object {
        /** The process-wide runtime shared by every tracking plugin. */
        val shared: SharedUnityRuntime = SharedUnityRuntime()
    }
}
