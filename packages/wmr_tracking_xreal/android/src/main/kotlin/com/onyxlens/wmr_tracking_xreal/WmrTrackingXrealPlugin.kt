package com.onyxlens.wmr_tracking_xreal

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
 * XREAL Air 2 Ultra head and 26-joint hand tracking Flutter plugin.
 *
 * Bridges Dart to an embedded Unity-as-a-Library (UaaL) scene running the
 * XREAL SDK for Unity 3.x:
 * - Requests `android.permission.CAMERA` when needed, guarded by
 *   [PendingStartGate] so `stop()` / `dispose()` / activity detach cancels an
 *   in-flight start before it can open a session.
 * - Sends `UnityRelayCommand` JSON to `WmrTrackingRelay.OnCommand` via
 *   `UnityPlayer.UnitySendMessage`.
 * - Exposes static callbacks ([onUnityFrame], [onUnityError],
 *   [onUnityGlassesModel]) invoked directly from C# over JNI /
 *   `AndroidJavaClass` so poses never travel over `UnitySendMessage`.
 */
class WmrTrackingXrealPlugin internal constructor(
    private val bridge: XrealUnityBridge,
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

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "wmr_tracking_xreal/methods")
        events = EventChannel(binding.binaryMessenger, "wmr_tracking_xreal/frames")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        runtime.register(GlassesVendor.XREAL, unityCallbacks)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        failPendingStart()
        stopTracking(reportError = false)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        eventSink = null
        appContext = null
        runtime.unregister(GlassesVendor.XREAL, unityCallbacks)
        runtime.release(GlassesVendor.XREAL)
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
            "start" -> start(MethodChannelStartReply(result))
            "stop" -> {
                failPendingStart(
                    "XREAL tracking stopped before the start completed",
                    TrackingStartStage.PENDING,
                )
                stopTracking(reportError = false)
                result.success(null)
            }
            "dispose" -> {
                failPendingStart(
                    "XREAL tracking source was disposed before the start completed",
                    TrackingStartStage.PENDING,
                )
                stopTracking(reportError = false)
                bridge.sendCommand(XrealRelayCommandBuilder.dispose())
                disposed = true
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
                "glassesModel" to XrealGlassesModelSpec.UNKNOWN.sdkName,
                "reason" to "XREAL Unity UaaL runtime (com.unity3d.player.UnityPlayer) is not linked",
                "permissions" to permissions,
            ) + stageFields
        }
        val reportedModel = bridge.queryGlassesModel()
        val modelSpec = XrealGlassesModelSpec.fromSdkName(reportedModel)
        if (!XrealGlassesModelSpec.isReported(reportedModel)) {
            // The unified Unity scene keeps the XREAL backend inactive until
            // `start`, so the model cannot be reported yet. Advertise the only
            // hand-tracking model and let the Unity start handshake report any
            // other model as `unsupported`.
            val air2Ultra = XrealGlassesModelSpec.AIR_2_ULTRA
            return mapOf(
                "unityAvailable" to true,
                "modelReported" to false,
                "supported" to true,
                "handTracking" to true,
                "headTracking" to true,
                "handGestures" to true,
                "passthroughCamera" to true,
                "handJointCount" to air2Ultra.handJointCount,
                "glassesModel" to modelSpec.sdkName,
                "reason" to null,
                "permissions" to permissions,
            ) + stageFields
        }
        val supported = modelSpec.head6Dof && modelSpec.handTracking
        val modelName = if (modelSpec == XrealGlassesModelSpec.UNKNOWN) {
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
                "XREAL hand tracking requires Air 2 Ultra (found $modelName)"
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
        val stage = runtime.stage(GlassesVendor.XREAL)
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

    private fun start(reply: StartReply) {
        if (disposed) {
            reply.error(
                ERROR_CLOSED,
                "XREAL tracking source has been disposed",
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
                "An XREAL tracking start is already pending",
                TrackingStartStage.PENDING,
            )
            return
        }
        if (!bridge.isUnityAvailable) {
            reply.error(
                ERROR_UNAVAILABLE,
                "XREAL Unity UaaL runtime is not linked",
                TrackingStartStage.LINK,
            )
            return
        }
        val current = activity
        if (current == null) {
            reply.error(
                ERROR_UNAVAILABLE,
                "No activity to host the XREAL Unity relay",
                TrackingStartStage.ACTIVITY,
            )
            return
        }
        val cameraGranted = try {
            ContextCompat.checkSelfPermission(current, PERMISSION_CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        } catch (error: Throwable) {
            reply.error(
                ERROR_UNAVAILABLE,
                error.message ?: "Failed to read the XREAL camera permission",
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
                "An XREAL tracking start is already pending",
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
                error.message ?: "Failed to request the XREAL camera permission",
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
                "XREAL camera permission was denied: $PERMISSION_CAMERA",
                TrackingStartStage.PERMISSION,
            )
            return true
        }
        if (activity == null) {
            reply.error(
                ERROR_UNAVAILABLE,
                "No activity to host the XREAL Unity relay",
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
            runtime.release(GlassesVendor.XREAL)
            playerHost.release()
            reply.error(
                ERROR_UNAVAILABLE,
                error.message ?: "XREAL Unity relay start failed",
                TrackingStartStage.START_FAILED,
            )
        }
    }

    private fun startUnityRelayGuarded(reply: StartReply) {
        // A new session must not report the previous session's stage.
        runtime.clearStage(GlassesVendor.XREAL)
        // XREAL-first must create and attach the one shared player before the
        // runtime is claimed; claiming first would let a claim without a view
        // own the runtime and make every later vendor merely reuse it.
        val host = playerHost.host(activity)
        if (!host.hosted) {
            reply.error(
                ERROR_UNAVAILABLE,
                host.detail ?: "No shared UnityPlayer is linked into this build",
                host.stage,
            )
            return
        }
        val claim = runtime.claim(GlassesVendor.XREAL) { host.hosted }
        if (!claim.granted) {
            runtime.release(GlassesVendor.XREAL)
            playerHost.release()
            reply.error(
                ERROR_UNAVAILABLE,
                "No shared UnityPlayer is linked into this build",
                TrackingStartStage.CLAIM,
            )
            return
        }
        val reportedModel = bridge.queryGlassesModel()
        val modelSpec = XrealGlassesModelSpec.fromSdkName(reportedModel)
        if (XrealGlassesModelSpec.isReported(reportedModel) &&
            (!modelSpec.handTracking || !modelSpec.head6Dof)
        ) {
            runtime.release(GlassesVendor.XREAL)
            playerHost.release()
            val modelName = if (modelSpec == XrealGlassesModelSpec.UNKNOWN) {
                reportedModel?.takeIf { it.isNotBlank() } ?: modelSpec.sdkName
            } else {
                modelSpec.sdkName
            }
            reply.error(
                ERROR_UNSUPPORTED,
                "XREAL hand tracking requires Air 2 Ultra (found $modelName)",
                TrackingStartStage.MODEL,
            )
            return
        }
        val commandJson = XrealRelayCommandBuilder.start()
        started = true
        // A player created by this start is still inside
        // UnityPlayerForActivityOrService init, where UnitySendMessage
        // SIGSEGVs the process (ONY-776). Queue the start until the scene
        // reports `playerHosted`; a warm scene already reported it, so it can
        // take the command immediately.
        pendingStartCommand = commandJson
        if (runtime.hasHostedScene() && !flushPendingStart()) {
            started = false
            runtime.release(GlassesVendor.XREAL)
            playerHost.release()
            reply.error(
                ERROR_UNAVAILABLE,
                "Failed to dispatch start command to Unity relay",
                TrackingStartStage.COMMAND,
            )
            return
        }
        reply.success(stageFields())
    }

    /**
     * Replays the start command once the hosted scene is alive. No-op when the
     * command was consumed, the source stopped, or the scene reported late.
     *
     * @return true when a command was sent successfully; false when nothing was
     *   pending or the bridge refused it.
     */
    internal fun flushPendingStart(): Boolean {
        val command = pendingStartCommand ?: return false
        pendingStartCommand = null
        if (!started) return false
        return bridge.sendCommand(command)
    }

    /** Test seam for the static `onUnityStage` entry point the C# rig calls. */
    internal fun deliverUnityStage(stage: String, stereoMode: String?) {
        unityCallbacks.onStage(stage, stereoMode)
    }

    private fun stopTracking(reportError: Boolean) {
        failPendingStart()
        pendingStartCommand = null
        val wasStarted = started
        started = false
        if (wasStarted) {
            bridge.sendCommand(XrealRelayCommandBuilder.stop())
        }
        runtime.release(GlassesVendor.XREAL)
        runtime.clearStage(GlassesVendor.XREAL)
        // On stop the display goes back to Flutter; the player can stay in the
        // process and be hosted again by the next start.
        playerHost.release()
        if (reportError) {
            eventSink?.error(
                ERROR_UNAVAILABLE,
                "XREAL host activity was detached",
                mapOf("stage" to TrackingStartStage.DETACH),
            )
        }
    }

    private fun failPendingStart(
        message: String = "XREAL host activity was detached",
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
        bridge.sendCommand(XrealRelayCommandBuilder.stop())
        runtime.release(GlassesVendor.XREAL)
        runtime.clearStage(GlassesVendor.XREAL)
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
        internal const val PERMISSION_REQUEST_CODE = 0x5852
        internal const val PERMISSION_CAMERA = "android.permission.CAMERA"
        internal const val ERROR_PERMISSION_DENIED = "permissionDenied"
        internal const val ERROR_UNSUPPORTED = "unsupported"
        internal const val ERROR_UNAVAILABLE = "unavailable"
        internal const val ERROR_PROTOCOL = "protocol"
        internal const val ERROR_CLOSED = "closed"
        internal const val STAGE_NOT_HOSTED = "notHosted"
        internal const val STEREO_UNKNOWN = "unknown"

        /**
         * Called by C# `XrealTrackingRelayBridge` when a new tracking frame is
         * ready. The shared runtime routes it to the XREAL plugin, and that
         * plugin marshals delivery onto the Android main thread.
         */
        @JvmStatic
        fun onUnityFrame(frameJson: String) {
            SharedUnityRuntime.shared.dispatchFrame(GlassesVendor.XREAL, frameJson)
        }

        /**
         * Called by C# `XrealTrackingRelayBridge` when the XREAL runtime
         * reports a failure (`unsupported`, `unavailable`, `permissionDenied`,
         * `protocol`).
         */
        @JvmStatic
        fun onUnityError(code: String, message: String) {
            SharedUnityRuntime.shared.dispatchError(GlassesVendor.XREAL, code, message)
        }

        /**
         * Called by C# `XrealTrackingRelayBridge` after querying
         * `XREALPlugin.GetDeviceType()`. The model is the second confirmation
         * after native detection.
         */
        @JvmStatic
        fun onUnityGlassesModel(modelName: String?) {
            SharedUnityRuntime.shared.dispatchGlassesModel(GlassesVendor.XREAL, modelName)
        }

        /**
         * Called by the hosted scene when it reaches a startup stage. The scene
         * is shared with VITURE, so the report is attributed to whichever
         * vendor owns the shared runtime; ONY-707 points the C# rig here while
         * XREAL is active.
         */
        @JvmStatic
        fun onUnityStage(stage: String, stereoMode: String?) {
            SharedUnityRuntime.shared.dispatchHostStage(stage, stereoMode)
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
