package com.onyxlens.wmr_tracking_viture

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.onyxlens.wmr_tracking_dispatch.GlassesVendor
import com.onyxlens.wmr_tracking_dispatch.PlayerHost
import com.onyxlens.wmr_tracking_dispatch.SharedUnityRuntime
import com.onyxlens.wmr_tracking_dispatch.TrackingStartStage
import com.onyxlens.wmr_tracking_dispatch.UnityPlayerHost
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * VITURE Pro Neckband head and 26-joint hand tracking Flutter plugin.
 *
 * Bridges Dart to an embedded Unity-as-a-Library (UaaL) scene running the
 * VITURE XR SDK for Unity (v0.9.0, `Viture.XR.VitureXR`) on the VITURE Pro Neckband:
 * - Requests `android.permission.CAMERA` when needed, guarded by
 *   [PendingStartGate] so `stop()` / `dispose()` / activity detach cancels an
 *   in-flight start before it can open a session.
 * - Sends `UnityRelayCommand` JSON to `WmrTrackingRelay.OnCommand` via
 *   `UnityPlayer.UnitySendMessage`.
 * - Exposes static callbacks ([onUnityFrame], [onUnityError],
 *   [onUnityGlassesModel]) invoked directly from C# over JNI /
 *   `AndroidJavaClass` so poses never travel over `UnitySendMessage`.
 */
class WmrTrackingViturePlugin internal constructor(
    private val bridge: VitureUnityBridge,
    private val runtime: SharedUnityRuntime = SharedUnityRuntime.shared,
    private val playerHost: PlayerHost = UnityPlayerHost.shared,
) :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    constructor() : this(ReflectiveUnityBridge())

    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var eventSink: EventChannel.EventSink? = null
    internal val pendingStart = PendingStartGate()

    /** Routes the shared UnityPlayer callbacks for this vendor onto Flutter. */
    private val unityCallbacks = object : SharedUnityRuntime.Handler {
        override fun onFrame(frameJson: String) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                deliverUnityFrame(frameJson)
            } else {
                mainHandler.post { deliverUnityFrame(frameJson) }
            }
        }

        override fun onError(code: String, message: String) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                deliverUnityError(code, message)
            } else {
                mainHandler.post { deliverUnityError(code, message) }
            }
        }

        override fun onGlassesModel(modelName: String?) = Unit

        override fun onStage(stage: String, stereoMode: String?) {
            if (stage != UnityPlayerHost.STAGE_PLAYER_HOSTED) return
            if (Looper.myLooper() == Looper.getMainLooper()) {
                flushPendingStart()
            } else {
                mainHandler.post { flushPendingStart() }
            }
        }
    }

    private var started = false
    private var disposed = false
    private var pendingStartCommand: String? = null
    private var pendingFilterMode: String = "responsive"
    private var pendingAimSensitivity: String = "high"

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "wmr_tracking_viture/methods")
        events = EventChannel(binding.binaryMessenger, "wmr_tracking_viture/frames")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        runtime.register(GlassesVendor.VITURE, unityCallbacks)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        failPendingStart()
        stopTracking(reportError = false)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        eventSink = null
        appContext = null
        runtime.unregister(GlassesVendor.VITURE, unityCallbacks)
        runtime.release(GlassesVendor.VITURE)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity(reportError = true)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        detachActivity(reportError = true)
    }

    private fun detachActivity(reportError: Boolean) {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        failPendingStart()
        stopTracking(reportError)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(capabilities())
            "start" -> {
                val args = call.arguments as? Map<*, *>
                val filterMode = (args?.get("filter_mode") as? String) ?: "responsive"
                val aimSensitivity = (args?.get("aim_sensitivity") as? String) ?: "high"
                start(filterMode, aimSensitivity, MethodChannelStartReply(result))
            }
            "stop" -> {
                failPendingStart(
                    "VITURE tracking stopped before the start completed",
                    TrackingStartStage.PENDING,
                )
                stopTracking(reportError = false)
                result.success(null)
            }
            "dispose" -> {
                failPendingStart(
                    "VITURE tracking source was disposed before the start completed",
                    TrackingStartStage.PENDING,
                )
                stopTracking(reportError = false)
                bridge.sendCommand(VitureRelayCommandBuilder.dispose())
                disposed = true
                result.success(null)
            }
            "command" -> {
                if (disposed) {
                    result.error(ERROR_CLOSED, "VITURE tracking source has been disposed", null)
                    return
                }
                val args = call.arguments as? Map<*, *>
                val cmd = args?.get("cmd") as? String
                if (cmd.isNullOrBlank()) {
                    result.error(ERROR_PROTOCOL, "Relay command requires a non-empty cmd", null)
                    return
                }
                val vendor = (args["vendor"] as? String) ?: "viture"
                val rawOptions = args["options"] as? Map<*, *>
                val options = linkedMapOf<String, Any?>()
                rawOptions?.forEach { (k, v) ->
                    if (k is String) options[k] = v
                }
                val payload = VitureRelayCommandBuilder.buildCommand(cmd, vendor, options)
                if (!bridge.sendCommand(payload)) {
                    result.error(ERROR_UNAVAILABLE, "Unity UaaL relay is not available", null)
                    return
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    internal fun capabilities(): Map<String, Any?> {
        disposed = false
        val context = activity ?: appContext
        val permissions = if (context != null) {
            mapOf("camera" to permissionState(context, PERMISSION_CAMERA))
        } else {
            emptyMap()
        }
        val stageFields = stageFields()
        if (!bridge.isUnityAvailable) {
            return mapOf(
                "unityAvailable" to false,
                "supported" to false,
                "handTracking" to false,
                "headTracking" to false,
                "handJointCount" to 0,
                "glassesModel" to VitureGlassesModelSpec.UNKNOWN.sdkName,
                "reason" to "VITURE Unity UaaL runtime (com.unity3d.player.UnityPlayer) is not linked",
                "permissions" to permissions,
            ) + stageFields
        }
        val reportedModel = bridge.queryGlassesModel()
        val modelSpec = VitureGlassesModelSpec.fromSdkName(reportedModel)
        if (!VitureGlassesModelSpec.isReported(reportedModel)) {
            // The unified Unity scene keeps the VITURE backend inactive until
            // `start`, so the model cannot be reported yet. Advertise the only
            // hand-tracking model and let the Unity start handshake report any
            // other model as `unsupported`.
            val lumaUltra = VitureGlassesModelSpec.LUMA_ULTRA
            return mapOf(
                "unityAvailable" to true,
                "modelReported" to false,
                "supported" to true,
                "handTracking" to true,
                "headTracking" to true,
                "handGestures" to true,
                "passthroughCamera" to true,
                "handJointCount" to lumaUltra.handJointCount,
                "glassesModel" to modelSpec.sdkName,
                "reason" to null,
                "permissions" to permissions,
            ) + stageFields
        }
        val supported = modelSpec.head6Dof && modelSpec.handTracking
        val modelName = if (modelSpec == VitureGlassesModelSpec.UNKNOWN) {
            reportedModel?.takeIf { it.isNotBlank() } ?: modelSpec.sdkName
        } else {
            modelSpec.sdkName
        }
        return mapOf(
            "unityAvailable" to true,
            "modelReported" to true,
            "supported" to supported,
            "handTracking" to modelSpec.handTracking,
            "headTracking" to modelSpec.head6Dof,
            "handGestures" to modelSpec.handTracking,
            "passthroughCamera" to supported,
            "handJointCount" to modelSpec.handJointCount,
            "glassesModel" to modelName,
            "reason" to if (supported) {
                null
            } else {
                "VITURE hand tracking requires LumaUltra on Pro Neckband (found $modelName)"
            },
            "permissions" to permissions,
        ) + stageFields
    }

    /**
     * The hosting/display report the tester reads: whether this process put a
     * player on screen, the stereo mode the scene last reported, and the last
     * startup stage it reached.
     */
    internal fun stageFields(): Map<String, Any?> {
        val stage = runtime.stage(GlassesVendor.VITURE)
        return mapOf(
            "playerHosted" to playerHost.isHosted,
            "stereoMode" to (stage?.stereoMode ?: STEREO_UNKNOWN),
            "stage" to (stage?.stage
                ?: if (playerHost.isHosted) {
                    UnityPlayerHost.STAGE_PLAYER_HOSTED
                } else {
                    STAGE_NOT_HOSTED
                }),
        )
    }

    private fun permissionState(context: Context, permission: String): String =
        when (ContextCompat.checkSelfPermission(context, permission)) {
            PackageManager.PERMISSION_GRANTED -> "granted"
            else -> "missing"
        }

    private fun start(filterMode: String, aimSensitivity: String, reply: StartReply) {
        if (disposed) {
            reply.error(
                ERROR_CLOSED,
                "VITURE tracking source has been disposed",
                TrackingStartStage.DISPOSED,
            )
            return
        }
        if (started) {
            reply.success(stageFields())
            return
        }
        if (pendingStart.isPending) {
            reply.error(
                ERROR_UNAVAILABLE,
                "A VITURE tracking start is already pending",
                TrackingStartStage.PENDING,
            )
            return
        }
        if (!bridge.isUnityAvailable) {
            reply.error(
                ERROR_UNAVAILABLE,
                "VITURE Unity UaaL runtime is not linked",
                TrackingStartStage.LINK,
            )
            return
        }
        val current = activity
        if (current == null) {
            reply.error(
                ERROR_UNAVAILABLE,
                "No activity to host the VITURE Unity relay",
                TrackingStartStage.ACTIVITY,
            )
            return
        }
        pendingFilterMode = filterMode
        pendingAimSensitivity = aimSensitivity
        val cameraGranted = try {
            ContextCompat.checkSelfPermission(current, PERMISSION_CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        } catch (error: Throwable) {
            reply.error(
                ERROR_UNAVAILABLE,
                error.message ?: "Failed to read the VITURE camera permission",
                TrackingStartStage.PERMISSION,
            )
            return
        }
        if (cameraGranted) {
            startUnityRelay(reply)
            return
        }
        if (!pendingStart.hold(reply)) {
            reply.error(
                ERROR_UNAVAILABLE,
                "A VITURE tracking start is already pending",
                TrackingStartStage.PENDING,
            )
            return
        }
        try {
            ActivityCompat.requestPermissions(
                current,
                arrayOf(PERMISSION_CAMERA),
                PERMISSION_REQUEST_CODE,
            )
        } catch (error: Throwable) {
            pendingStart.cancel(
                ERROR_UNAVAILABLE,
                error.message ?: "Failed to request the VITURE camera permission",
                TrackingStartStage.PERMISSION,
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val reply = pendingStart.resolve() ?: return true
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            reply.error(
                ERROR_PERMISSION_DENIED,
                "VITURE camera permission was denied: $PERMISSION_CAMERA",
                TrackingStartStage.PERMISSION,
            )
            return true
        }
        if (activity == null) {
            reply.error(
                ERROR_UNAVAILABLE,
                "No activity to host the VITURE Unity relay",
                TrackingStartStage.ACTIVITY,
            )
            return true
        }
        startUnityRelay(reply)
        return true
    }

    internal fun startUnityRelay(reply: StartReply) {
        try {
            startUnityRelayGuarded(reply)
        } catch (error: Throwable) {
            runtime.release(GlassesVendor.VITURE)
            playerHost.release()
            reply.error(
                ERROR_UNAVAILABLE,
                error.message ?: "VITURE Unity relay start failed",
                TrackingStartStage.START_FAILED,
            )
        }
    }

    private fun startUnityRelayGuarded(reply: StartReply) {
        // A new session must not report the previous session's stage.
        runtime.clearStage(GlassesVendor.VITURE)
        // The player has to exist before UnitySendMessage can reach the scene.
        // Host it in the foreground activity and attach its view full-screen,
        // then claim the shared runtime only after it reports an attached player.
        val host = playerHost.host(activity)
        if (!host.hosted) {
            reply.error(
                ERROR_UNAVAILABLE,
                host.detail ?: "No shared UnityPlayer is linked into this build",
                host.stage,
            )
            return
        }
        val claim = runtime.claim(GlassesVendor.VITURE) { host.hosted }
        if (!claim.granted) {
            runtime.release(GlassesVendor.VITURE)
            playerHost.release()
            reply.error(
                ERROR_UNAVAILABLE,
                "No shared UnityPlayer is linked into this build",
                TrackingStartStage.CLAIM,
            )
            return
        }
        val reportedModel = bridge.queryGlassesModel()
        val modelSpec = VitureGlassesModelSpec.fromSdkName(reportedModel)
        if (VitureGlassesModelSpec.isReported(reportedModel) &&
            (!modelSpec.handTracking || !modelSpec.head6Dof)
        ) {
            runtime.release(GlassesVendor.VITURE)
            playerHost.release()
            val modelName = if (modelSpec == VitureGlassesModelSpec.UNKNOWN) {
                reportedModel?.takeIf { it.isNotBlank() } ?: modelSpec.sdkName
            } else {
                modelSpec.sdkName
            }
            reply.error(
                ERROR_UNSUPPORTED,
                "VITURE hand tracking requires LumaUltra on Pro Neckband (found $modelName)",
                TrackingStartStage.MODEL,
            )
            return
        }
        val commandJson = VitureRelayCommandBuilder.start(
            filterMode = pendingFilterMode,
            aimSensitivity = pendingAimSensitivity,
        )
        if (!bridge.sendCommand(commandJson)) {
            runtime.release(GlassesVendor.VITURE)
            playerHost.release()
            reply.error(
                ERROR_UNAVAILABLE,
                "Failed to dispatch start command to Unity relay",
                TrackingStartStage.COMMAND,
            )
            return
        }
        // A player created for this start reaches `Awake` after the constructor
        // returns, so the first `UnitySendMessage` may land before the scene
        // exists. Keep the command and replay it when the scene reports
        // `playerHosted`; a duplicate start is idempotent in the bridge.
        pendingStartCommand = commandJson
        started = true
        reply.success(stageFields())
    }

    /**
     * Replays the start command once the hosted scene is alive. No-op when the
     * command was consumed, the source stopped, or the scene reported late.
     */
    internal fun flushPendingStart() {
        val command = pendingStartCommand ?: return
        pendingStartCommand = null
        if (!started) return
        bridge.sendCommand(command)
    }

    private fun stopTracking(reportError: Boolean) {
        failPendingStart()
        pendingStartCommand = null
        val wasStarted = started
        started = false
        if (wasStarted) {
            bridge.sendCommand(VitureRelayCommandBuilder.stop())
        }
        runtime.release(GlassesVendor.VITURE)
        runtime.clearStage(GlassesVendor.VITURE)
        // On stop the display goes back to Flutter; the player can stay in the
        // process and be hosted again by the next start.
        playerHost.release()
        if (reportError) {
            eventSink?.error(
                ERROR_UNAVAILABLE,
                "VITURE host activity was detached",
                mapOf("stage" to TrackingStartStage.DETACH),
            )
        }
    }

    private fun failPendingStart(
        message: String = "VITURE host activity was detached",
        stage: String = TrackingStartStage.DETACH,
    ) {
        pendingStart.cancel(ERROR_UNAVAILABLE, message, stage)
    }

    internal fun deliverUnityFrame(frameJson: String) {
        if (!started) return
        eventSink?.success(frameJson)
    }

    internal fun deliverUnityError(code: String, message: String) {
        if (!started) return
        started = false
        pendingStartCommand = null
        // The C# bridge keeps its own `_running` flag; stop the session before
        // detaching so a later start does not see an already-running relay.
        bridge.sendCommand(VitureRelayCommandBuilder.stop())
        runtime.release(GlassesVendor.VITURE)
        runtime.clearStage(GlassesVendor.VITURE)
        playerHost.release()
        eventSink?.error(code, message, mapOf("stage" to TrackingStartStage.RUNTIME))
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        stopTracking(reportError = false)
    }

    companion object {
        internal const val PERMISSION_REQUEST_CODE = 0x5756
        internal const val PERMISSION_CAMERA = "android.permission.CAMERA"
        internal const val ERROR_PERMISSION_DENIED = "permissionDenied"
        internal const val ERROR_UNSUPPORTED = "unsupported"
        internal const val ERROR_UNAVAILABLE = "unavailable"
        internal const val ERROR_PROTOCOL = "protocol"
        internal const val ERROR_CLOSED = "closed"
        internal const val STAGE_NOT_HOSTED = "notHosted"
        internal const val STEREO_UNKNOWN = "unknown"

        /**
         * Called by C# `VitureTrackingRelayBridge` when a new tracking frame is
         * ready. The shared runtime routes it to the VITURE plugin, and that
         * plugin marshals delivery onto the Android main thread.
         */
        @JvmStatic
        fun onUnityFrame(frameJson: String) {
            SharedUnityRuntime.shared.dispatchFrame(GlassesVendor.VITURE, frameJson)
        }

        /**
         * Called by C# `VitureTrackingRelayBridge` when the VITURE SDK reports
         * a runtime failure (`unsupported`, `unavailable`, `permissionDenied`,
         * `protocol`).
         */
        @JvmStatic
        fun onUnityError(code: String, message: String) {
            SharedUnityRuntime.shared.dispatchError(GlassesVendor.VITURE, code, message)
        }

        /**
         * Called by C# `VitureTrackingRelayBridge` after querying
         * `VitureXR.Glasses.GetGlassesModel()`. The model is the second
         * confirmation after native detection.
         */
        @JvmStatic
        fun onUnityGlassesModel(modelName: String?) {
            SharedUnityRuntime.shared.dispatchGlassesModel(GlassesVendor.VITURE, modelName)
        }

        /**
         * Called by C# `WmrStereoCameraRig` when the hosted scene reaches a
         * startup stage. The stereo mode is `multiPass`, `singlePass`,
         * `singlePassInstanced` or `unknown`; a mono player is reported as
         * `unknown` because the VITURE loader never presents mono as stereo.
         */
        @JvmStatic
        fun onUnityStage(stage: String, stereoMode: String?) {
            SharedUnityRuntime.shared.dispatchStage(GlassesVendor.VITURE, stage, stereoMode)
        }
    }
}

private class MethodChannelStartReply(
    private val result: MethodChannel.Result,
) : StartReply {
    override fun success(report: Map<String, Any?>) = result.success(report)

    override fun error(code: String, message: String, stage: String?) =
        result.error(code, message, stage?.let { mapOf("stage" to it) })
}
