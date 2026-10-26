package com.onyxlens.wmr_tracking_xreal

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.onyxlens.wmr_tracking_dispatch.GlassesVendor
import com.onyxlens.wmr_tracking_dispatch.SharedUnityRuntime
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
    private val pendingStart = PendingStartGate()

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
    }

    private var started = false
    private var disposed = false

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
                failPendingStart("XREAL tracking stopped before the start completed")
                stopTracking(reportError = false)
                result.success(null)
            }
            "dispose" -> {
                failPendingStart("XREAL tracking source was disposed before the start completed")
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
            )
        }
        val modelSpec = XrealGlassesModelSpec.fromSdkName(bridge.queryGlassesModel())
        val supported = modelSpec.head6Dof && modelSpec.handTracking
        return mapOf(
            "unityAvailable" to true,
            "supported" to supported,
            "handTracking" to modelSpec.handTracking,
            "headTracking" to modelSpec.head6Dof,
            "handGestures" to modelSpec.handTracking,
            "passthroughCamera" to supported,
            "handJointCount" to modelSpec.handJointCount,
            "glassesModel" to modelSpec.sdkName,
            "reason" to if (supported) {
                null
            } else {
                "XREAL hand tracking requires Air 2 Ultra (found ${modelSpec.sdkName})"
            },
            "permissions" to permissions,
        )
    }

    private fun permissionState(context: Context, permission: String): String =
        when (ContextCompat.checkSelfPermission(context, permission)) {
            PackageManager.PERMISSION_GRANTED -> "granted"
            else -> "missing"
        }

    private fun start(reply: StartReply) {
        if (disposed) {
            reply.error(ERROR_CLOSED, "XREAL tracking source has been disposed")
            return
        }
        if (started) {
            reply.success()
            return
        }
        if (pendingStart.isPending) {
            reply.error(ERROR_UNAVAILABLE, "An XREAL tracking start is already pending")
            return
        }
        if (!bridge.isUnityAvailable) {
            reply.error(ERROR_UNAVAILABLE, "XREAL Unity UaaL runtime is not linked")
            return
        }
        val current = activity
        if (current == null) {
            reply.error(ERROR_UNAVAILABLE, "No activity to host the XREAL Unity relay")
            return
        }
        if (ContextCompat.checkSelfPermission(current, PERMISSION_CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            startUnityRelay(reply)
            return
        }
        pendingStart.hold(reply)
        ActivityCompat.requestPermissions(
            current,
            arrayOf(PERMISSION_CAMERA),
            PERMISSION_REQUEST_CODE,
        )
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
            )
            return true
        }
        if (activity == null) {
            reply.error(ERROR_UNAVAILABLE, "No activity to host the XREAL Unity relay")
            return true
        }
        startUnityRelay(reply)
        return true
    }

    internal fun startUnityRelay(reply: StartReply) {
        val claim = runtime.claim(GlassesVendor.XREAL)
        if (!claim.granted) {
            reply.error(ERROR_UNAVAILABLE, "No shared UnityPlayer is linked into this build")
            return
        }
        val modelSpec = XrealGlassesModelSpec.fromSdkName(bridge.queryGlassesModel())
        if (!modelSpec.handTracking || !modelSpec.head6Dof) {
            runtime.release(GlassesVendor.XREAL)
            reply.error(
                ERROR_UNSUPPORTED,
                "XREAL hand tracking requires Air 2 Ultra (found ${modelSpec.sdkName})",
            )
            return
        }
        if (!bridge.sendCommand(XrealRelayCommandBuilder.start())) {
            runtime.release(GlassesVendor.XREAL)
            reply.error(ERROR_UNAVAILABLE, "Failed to dispatch start command to Unity relay")
            return
        }
        started = true
        reply.success()
    }

    private fun stopTracking(reportError: Boolean) {
        failPendingStart()
        val wasStarted = started
        started = false
        if (wasStarted) {
            bridge.sendCommand(XrealRelayCommandBuilder.stop())
        }
        runtime.release(GlassesVendor.XREAL)
        if (reportError) {
            eventSink?.error(ERROR_UNAVAILABLE, "XREAL host activity was detached", null)
        }
    }

    private fun failPendingStart(message: String = "XREAL host activity was detached") {
        pendingStart.cancel(ERROR_UNAVAILABLE, message)
    }

    internal fun deliverUnityFrame(frameJson: String) {
        if (!started) return
        eventSink?.success(frameJson)
    }

    internal fun deliverUnityError(code: String, message: String) {
        if (!started) return
        started = false
        runtime.release(GlassesVendor.XREAL)
        bridge.sendCommand(XrealRelayCommandBuilder.stop())
        eventSink?.error(code, message, null)
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
    }
}

private class MethodChannelStartReply(
    private val result: MethodChannel.Result,
) : StartReply {
    override fun success() = result.success(null)

    override fun error(code: String, message: String) = result.error(code, message, null)
}
