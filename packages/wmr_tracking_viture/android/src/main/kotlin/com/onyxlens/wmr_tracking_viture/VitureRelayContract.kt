package com.onyxlens.wmr_tracking_viture

import com.onyxlens.wmr_tracking_dispatch.GlassesVendor
import com.onyxlens.wmr_tracking_dispatch.SharedUnityRuntime

/**
 * Capability matrix for `VitureXR.Glasses.GetGlassesModel()` in the VITURE
 * Unity SDK (v0.9.0, `Viture.XR.VitureXR`).
 *
 * Only `LumaUltra` supports 6DoF head pose and 26-joint XR Hands skeletal
 * tracking on the Pro Neckband; other glasses models are 3DoF head-only.
 */
internal enum class VitureGlassesModelSpec(
    val sdkName: String,
    val head6Dof: Boolean,
    val handTracking: Boolean,
    val handJointCount: Int,
) {
    ONE("One", head6Dof = false, handTracking = false, handJointCount = 0),
    ONE_LITE("OneLite", head6Dof = false, handTracking = false, handJointCount = 0),
    PRO("Pro", head6Dof = false, handTracking = false, handJointCount = 0),
    PRO_2("Pro2", head6Dof = false, handTracking = false, handJointCount = 0),
    LUMA("Luma", head6Dof = false, handTracking = false, handJointCount = 0),
    LUMA_PRO("LumaPro", head6Dof = false, handTracking = false, handJointCount = 0),
    LUMA_ULTRA("LumaUltra", head6Dof = true, handTracking = true, handJointCount = 26),
    LUMA_CYBER("LumaCyber", head6Dof = false, handTracking = false, handJointCount = 0),
    BEAST("Beast", head6Dof = false, handTracking = false, handJointCount = 0),
    UNKNOWN("Unknown", head6Dof = false, handTracking = false, handJointCount = 0);

    companion object {
        fun fromSdkName(raw: String?): VitureGlassesModelSpec {
            if (raw.isNullOrBlank()) return UNKNOWN
            val normalized = raw.replace("_", "").replace("-", "").lowercase()
            return values().firstOrNull { it.sdkName.lowercase() == normalized } ?: UNKNOWN
        }

        /**
         * Whether [raw] is a model the SDK actually reported.
         *
         * A null, blank or `Unknown` value means the Unity scene has not
         * reported the model yet, either because the unified scene keeps its
         * vendor backend inactive until `start` or because the SDK query ran
         * before the XR loader was initialised. Callers must defer to the
         * Unity start handshake instead of failing closed in that case.
         *
         * Any other name is reported even when [fromSdkName] cannot classify
         * it, so an unrecognised model still fails closed as `unsupported`.
         */
        fun isReported(raw: String?): Boolean =
            !raw.isNullOrBlank() &&
                raw.replace("_", "").replace("-", "").lowercase() != "unknown"
    }
}

/**
 * Encodes versioned JSON command envelopes sent via
 * `UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json)`.
 */
internal object VitureRelayCommandBuilder {
    const val DEFAULT_GAME_OBJECT = "WmrTrackingRelay"
    const val DEFAULT_METHOD = "OnCommand"

    fun start(
        filterMode: String = "responsive",
        aimSensitivity: String = "high",
    ): String =
        buildCommand(
            cmd = "start",
            options = linkedMapOf(
                "filter_mode" to filterMode,
                "aim_sensitivity" to aimSensitivity,
            ),
        )

    fun stop(): String = buildCommand("stop")

    fun dispose(): String = buildCommand("dispose")

    fun recenter(): String = buildCommand("recenter")

    fun buildCommand(
        cmd: String,
        vendor: String = "viture",
        options: Map<String, Any?> = emptyMap(),
    ): String {
        require(cmd.isNotBlank()) { "cmd must not be blank" }
        val sb = StringBuilder()
        sb.append("""{"v":1,"cmd":"""").append(escapeJson(cmd)).append('"')
        if (vendor.isNotBlank()) {
            sb.append(""","vendor":"""").append(escapeJson(vendor)).append('"')
        }
        val nonNullOptions = options.entries.filter { it.value != null }
        if (nonNullOptions.isNotEmpty()) {
            sb.append(""","options":{""")
            nonNullOptions.forEachIndexed { index, (key, value) ->
                if (index > 0) sb.append(',')
                sb.append('"').append(escapeJson(key)).append("""":""")
                when (value) {
                    is Boolean, is Int, is Long, is Double, is Float -> sb.append(value)
                    else -> sb.append('"').append(escapeJson(value.toString())).append('"')
                }
            }
            sb.append('}')
        }
        sb.append('}')
        return sb.toString()
    }

    private fun escapeJson(value: String): String =
        value.replace("\\", "\\\\").replace("\"", "\\\"")
}

/**
 * Seam for communicating with the embedded Unity-as-a-Library runtime.
 *
 * Production uses [ReflectiveUnityBridge] so the plugin compiles cleanly even
 * when the proprietary Unity 6000.0+ UaaL export (`unityLibrary`) and VITURE
 * XR SDK (`com.viture.xr` v0.9.0, `Viture.XR.VitureXR`) are not present in the CI build environment.
 */
internal interface VitureUnityBridge {
    val isUnityAvailable: Boolean

    /** Returns the connected glasses model name (`LumaUltra`, `Luma`, ...), or null if unavailable. */
    fun queryGlassesModel(): String?

    /** Sends a command payload to [gameObject].[method] via `UnitySendMessage`. */
    fun sendCommand(
        payloadJson: String,
        gameObject: String = VitureRelayCommandBuilder.DEFAULT_GAME_OBJECT,
        method: String = VitureRelayCommandBuilder.DEFAULT_METHOD,
    ): Boolean
}

internal class ReflectiveUnityBridge : VitureUnityBridge {
    private val unityPlayerClass: Class<*>? = try {
        Class.forName("com.unity3d.player.UnityPlayer")
    } catch (_: Throwable) {
        null
    }

    override val isUnityAvailable: Boolean
        get() = unityPlayerClass != null

    override fun queryGlassesModel(): String? {
        // When the C# bridge registers the detected model via
        // WmrTrackingViturePlugin.onUnityGlassesModel(...), the shared runtime
        // keeps it; otherwise return null until the Unity scene reports it.
        return SharedUnityRuntime.shared.glassesModel(GlassesVendor.VITURE)
    }

    override fun sendCommand(
        payloadJson: String,
        gameObject: String,
        method: String,
    ): Boolean {
        val clazz = unityPlayerClass ?: return false
        return try {
            val sendMethod = clazz.getMethod(
                "UnitySendMessage",
                String::class.java,
                String::class.java,
                String::class.java,
            )
            sendMethod.invoke(null, gameObject, method, payloadJson)
            true
        } catch (_: Throwable) {
            false
        }
    }
}
