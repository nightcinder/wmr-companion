package com.onyxlens.wmr_tracking_xreal

import com.onyxlens.wmr_tracking_dispatch.GlassesVendor
import com.onyxlens.wmr_tracking_dispatch.SharedUnityRuntime

/**
 * Unity `XRHandJointID` to OpenXR 26-joint name table shared by the XREAL
 * Unity-as-a-Library relay.
 */
internal object XrealUnityJoints {
    private val unityToOpenXr: Map<String, String> = linkedMapOf(
        "Wrist" to "wrist",
        "Palm" to "palm",
        "ThumbMetacarpal" to "thumbMetacarpal",
        "ThumbProximal" to "thumbProximal",
        "ThumbDistal" to "thumbDistal",
        "ThumbTip" to "thumbTip",
        "IndexMetacarpal" to "indexMetacarpal",
        "IndexProximal" to "indexProximal",
        "IndexIntermediate" to "indexIntermediate",
        "IndexDistal" to "indexDistal",
        "IndexTip" to "indexTip",
        "MiddleMetacarpal" to "middleMetacarpal",
        "MiddleProximal" to "middleProximal",
        "MiddleIntermediate" to "middleIntermediate",
        "MiddleDistal" to "middleDistal",
        "MiddleTip" to "middleTip",
        "RingMetacarpal" to "ringMetacarpal",
        "RingProximal" to "ringProximal",
        "RingIntermediate" to "ringIntermediate",
        "RingDistal" to "ringDistal",
        "RingTip" to "ringTip",
        "LittleMetacarpal" to "littleMetacarpal",
        "LittleProximal" to "littleProximal",
        "LittleIntermediate" to "littleIntermediate",
        "LittleDistal" to "littleDistal",
        "LittleTip" to "littleTip",
    )

    private val openXrNames: Set<String> = unityToOpenXr.values.toSet()

    val allUnityJointIds: List<String> = unityToOpenXr.keys.toList()

    val allOpenXrJointNames: List<String> = unityToOpenXr.values.toList()

    /**
     * Maps either a Unity `XRHandJointID` name (`Palm`, `Wrist`, ...) or an
     * OpenXR camelCase joint name (`palm`, `wrist`, ...) to the canonical
     * OpenXR name, or null when unknown.
     */
    fun openXrName(raw: String): String? =
        unityToOpenXr[raw] ?: raw.takeIf { openXrNames.contains(it) }
}

/**
 * Left-handed Unity (`+X` right, `+Y` up, `+Z` forward) to right-handed OpenXR
 * (`+X` right, `+Y` up, `-Z` forward) pose conversion.
 *
 * `p = (x, y, z) -> (x, y, -z)` and `q = (qx, qy, qz, qw) -> (-qx, -qy, qz, qw)`.
 */
internal object UnityPoseConverter {
    fun unityToOpenXrPosition(x: Double, y: Double, z: Double): DoubleArray =
        doubleArrayOf(x, y, -z)

    fun openXrToUnityPosition(x: Double, y: Double, z: Double): DoubleArray =
        doubleArrayOf(x, y, -z)

    fun unityToOpenXrQuaternion(qx: Double, qy: Double, qz: Double, qw: Double): DoubleArray =
        doubleArrayOf(-qx, -qy, qz, qw)

    fun openXrToUnityQuaternion(qx: Double, qy: Double, qz: Double, qw: Double): DoubleArray =
        doubleArrayOf(-qx, -qy, qz, qw)
}

/**
 * Capability matrix for `XREALPlugin.GetDeviceType()`
 * (`Unity.XR.XREAL.XREALDeviceType`) in XREAL SDK 3.x.
 *
 * Only `Air2Ultra` supports 6DoF head pose and 26-joint XR Hands skeletal
 * tracking. The One series adds 6DoF head pose with the XREAL Eye but exposes
 * no hands; Air, Air 2 and Air 2 Pro are 3DoF head-only.
 */
internal enum class XrealGlassesModelSpec(
    val sdkName: String,
    val aliases: List<String>,
    val head6Dof: Boolean,
    val handTracking: Boolean,
    val handJointCount: Int,
) {
    AIR_2_ULTRA(
        "Air2Ultra",
        listOf("Air2Ultra", "XREALAir2Ultra", "NRAir2Ultra"),
        head6Dof = true,
        handTracking = true,
        handJointCount = 26,
    ),
    ONE(
        "One",
        listOf("One", "XREALOne", "NRGlassesOne"),
        head6Dof = true,
        handTracking = false,
        handJointCount = 0,
    ),
    ONE_PRO(
        "OnePro",
        listOf("OnePro", "XREALOnePro"),
        head6Dof = true,
        handTracking = false,
        handJointCount = 0,
    ),
    AIR(
        "Air",
        listOf("Air", "XREALAir", "NRAir"),
        head6Dof = false,
        handTracking = false,
        handJointCount = 0,
    ),
    AIR_2(
        "Air2",
        listOf("Air2", "XREALAir2", "NRAir2"),
        head6Dof = false,
        handTracking = false,
        handJointCount = 0,
    ),
    AIR_2_PRO(
        "Air2Pro",
        listOf("Air2Pro", "XREALAir2Pro", "NRAir2Pro"),
        head6Dof = false,
        handTracking = false,
        handJointCount = 0,
    ),
    LIGHT(
        "Light",
        listOf("Light", "XREALLight", "NRLight"),
        head6Dof = false,
        handTracking = false,
        handJointCount = 0,
    ),
    UNKNOWN(
        "Unknown",
        listOf("Unknown"),
        head6Dof = false,
        handTracking = false,
        handJointCount = 0,
    );

    companion object {
        fun fromSdkName(raw: String?): XrealGlassesModelSpec {
            if (raw.isNullOrBlank()) return UNKNOWN
            val normalized = normalize(raw)
            return values().firstOrNull { spec ->
                spec.aliases.any { normalize(it) == normalized }
            } ?: UNKNOWN
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
            !raw.isNullOrBlank() && normalize(raw) != "unknown"

        private fun normalize(value: String): String =
            value.replace(Regex("[^A-Za-z0-9]"), "").lowercase()
    }
}

/**
 * Encodes versioned JSON command envelopes sent via
 * `UnityPlayer.UnitySendMessage("WmrTrackingRelay", "OnCommand", json)`.
 */
internal object XrealRelayCommandBuilder {
    const val DEFAULT_GAME_OBJECT = "WmrTrackingRelay"
    const val DEFAULT_METHOD = "OnCommand"

    fun start(): String = buildCommand("start")

    fun stop(): String = buildCommand("stop")

    fun dispose(): String = buildCommand("dispose")

    fun buildCommand(cmd: String, vendor: String = "xreal"): String {
        require(cmd.isNotBlank()) { "cmd must not be blank" }
        val sb = StringBuilder()
        sb.append("""{"v":1,"cmd":"""").append(escapeJson(cmd)).append('"')
        if (vendor.isNotBlank()) {
            sb.append(""","vendor":"""").append(escapeJson(vendor)).append('"')
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
 * when the proprietary Unity 2021.3+/6000.0 UaaL export (`unityLibrary`) and
 * XREAL SDK for Unity 3.x (`com.xreal.xr`) are not present in the CI build
 * environment.
 */
internal interface XrealUnityBridge {
    val isUnityAvailable: Boolean

    /** Returns the connected device type name (`Air2Ultra`, `One`, ...), or null if unavailable. */
    fun queryGlassesModel(): String?

    /** Sends a command payload to [gameObject].[method] via `UnitySendMessage`. */
    fun sendCommand(
        payloadJson: String,
        gameObject: String = XrealRelayCommandBuilder.DEFAULT_GAME_OBJECT,
        method: String = XrealRelayCommandBuilder.DEFAULT_METHOD,
    ): Boolean
}

internal class ReflectiveUnityBridge : XrealUnityBridge {
    private val unityPlayerClass: Class<*>? = try {
        Class.forName("com.unity3d.player.UnityPlayer")
    } catch (_: Throwable) {
        null
    }

    override val isUnityAvailable: Boolean
        get() = unityPlayerClass != null

    override fun queryGlassesModel(): String? {
        // When the C# bridge registers the detected model via
        // WmrTrackingXrealPlugin.onUnityGlassesModel(...), the shared runtime
        // keeps it; otherwise return null until the Unity scene reports it.
        return SharedUnityRuntime.shared.glassesModel(GlassesVendor.XREAL)
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
