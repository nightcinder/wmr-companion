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
 * the runtime created; [createPlayer] is the injected creation seam, and both
 * plugins still check that `com.unity3d.player.UnityPlayer` is linked before
 * claiming. The other plugin reuses the same runtime
 * ([UnityClaimState.REUSED]) and never creates a second player. Frames, errors
 * addressed by vendor, with the owner as a fallback for untagged callbacks.
 * Android XR does not use Unity and never claims.
 */
class SharedUnityRuntime(
    private val createPlayer: () -> Boolean = { true },
) {
    /** Implemented by each vendor plugin to receive the shared callbacks. */
    interface Handler {
        fun onFrame(frameJson: String)

        fun onError(code: String, message: String)

        fun onGlassesModel(modelName: String?)
    }

    private var creationAttempted = false
    private var created = false
    private var owner: GlassesVendor? = null
    private val handlers = LinkedHashMap<GlassesVendor, Handler>()
    private val glassesModels = mutableMapOf<GlassesVendor, String?>()

    val ownerVendor: GlassesVendor?
        @Synchronized get() = owner

    @Synchronized
    fun claim(vendor: GlassesVendor): UnityClaim {
        if (vendor == GlassesVendor.NONE) {
            return UnityClaim(UnityClaimState.UNAVAILABLE, null)
        }
        if (!creationAttempted) {
            creationAttempted = true
            created = createPlayer()
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
