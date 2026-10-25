package com.onyxlens.wmr_tracking_viture

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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
 * VITURE XR SDK for Unity (v0.7.0) on the VITURE Pro Neckband:
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

    private var started = false
    private var disposed = false
    private var pendingFilterMode: String = "responsive"
    private var pendingAimSensitivity: String = "high"

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "wmr_tracking_viture/methods")
        events = EventChannel(binding.binaryMessenger, "wmr_tracking_viture/frames")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        activeInstance = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        failPendingStart()
        stopTracking(reportError = false)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        eventSink = null
        appContext = null
        if (activeInstance === this) {
            activeInstance = null
        }
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
                failPendingStart("VITURE tracking stopped before the start completed")
                stopTracking(reportError = false)
                result.success(null)
            }
            "dispose" -> {
                failPendingStart("VITURE tracking source was disposed before the start completed")
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
            )
        }
        val modelSpec = VitureGlassesModelSpec.fromSdkName(bridge.queryGlassesModel() ?: "LumaUltra")
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
                "VITURE hand tracking requires LumaUltra on Pro Neckband (found ${modelSpec.sdkName})"
            },
            "permissions" to permissions,
        )
    }

    private fun permissionState(context: Context, permission: String): String =
        when (ContextCompat.checkSelfPermission(context, permission)) {
            PackageManager.PERMISSION_GRANTED -> "granted"
            else -> "missing"
        }

    private fun start(filterMode: String, aimSensitivity: String, reply: StartReply) {
        if (disposed) {
            reply.error(ERROR_CLOSED, "VITURE tracking source has been disposed")
            return
        }
        if (started) {
            reply.success()
            return
        }
        if (pendingStart.isPending) {
            reply.error(ERROR_UNAVAILABLE, "A VITURE tracking start is already pending")
            return
        }
        if (!bridge.isUnityAvailable) {
            reply.error(ERROR_UNAVAILABLE, "VITURE Unity UaaL runtime is not linked")
            return
        }
        val current = activity
        if (current == null) {
            reply.error(ERROR_UNAVAILABLE, "No activity to host the VITURE Unity relay")
            return
        }
        pendingFilterMode = filterMode
        pendingAimSensitivity = aimSensitivity
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
                "VITURE camera permission was denied: $PERMISSION_CAMERA",
            )
            return true
        }
        if (activity == null) {
            reply.error(ERROR_UNAVAILABLE, "No activity to host the VITURE Unity relay")
            return true
        }
        startUnityRelay(reply)
        return true
    }

    private fun startUnityRelay(reply: StartReply) {
        val modelSpec = VitureGlassesModelSpec.fromSdkName(bridge.queryGlassesModel() ?: "LumaUltra")
        if (!modelSpec.handTracking || !modelSpec.head6Dof) {
            reply.error(
                ERROR_UNSUPPORTED,
                "VITURE hand tracking requires LumaUltra on Pro Neckband (found ${modelSpec.sdkName})",
            )
            return
        }
        val commandJson = VitureRelayCommandBuilder.start(
            filterMode = pendingFilterMode,
            aimSensitivity = pendingAimSensitivity,
        )
        if (!bridge.sendCommand(commandJson)) {
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
            bridge.sendCommand(VitureRelayCommandBuilder.stop())
        }
        if (reportError) {
            eventSink?.error(ERROR_UNAVAILABLE, "VITURE host activity was detached", null)
        }
    }

    private fun failPendingStart(message: String = "VITURE host activity was detached") {
        pendingStart.cancel(ERROR_UNAVAILABLE, message)
    }

    internal fun deliverUnityFrame(frameJson: String) {
        if (!started) return
        eventSink?.success(frameJson)
    }

    internal fun deliverUnityError(code: String, message: String) {
        if (!started) return
        started = false
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
        internal const val PERMISSION_REQUEST_CODE = 0x5756
        internal const val PERMISSION_CAMERA = "android.permission.CAMERA"
        internal const val ERROR_PERMISSION_DENIED = "permissionDenied"
        internal const val ERROR_UNSUPPORTED = "unsupported"
        internal const val ERROR_UNAVAILABLE = "unavailable"
        internal const val ERROR_PROTOCOL = "protocol"
        internal const val ERROR_CLOSED = "closed"

        @Volatile
        internal var activeInstance: WmrTrackingViturePlugin? = null

        @Volatile
        internal var reportedGlassesModel: String? = null

        /**
         * Called by C# `VitureTrackingRelayBridge` when a new tracking frame is
         * ready. Marshals delivery onto the Android main thread for Flutter's
         * `EventSink`.
         */
        @JvmStatic
        fun onUnityFrame(frameJson: String) {
            val plugin = activeInstance ?: return
            if (Looper.myLooper() == Looper.getMainLooper()) {
                plugin.deliverUnityFrame(frameJson)
            } else {
                plugin.mainHandler.post { plugin.deliverUnityFrame(frameJson) }
            }
        }

        /**
         * Called by C# `VitureTrackingRelayBridge` when the VITURE SDK reports
         * a runtime failure (`unsupported`, `unavailable`, `permissionDenied`,
         * `protocol`).
         */
        @JvmStatic
        fun onUnityError(code: String, message: String) {
            val plugin = activeInstance ?: return
            if (Looper.myLooper() == Looper.getMainLooper()) {
                plugin.deliverUnityError(code, message)
            } else {
                plugin.mainHandler.post { plugin.deliverUnityError(code, message) }
            }
        }

        /**
         * Called by C# `VitureTrackingRelayBridge` after querying
         * `VitureXR.Glasses.GetGlassesModel()`.
         */
        @JvmStatic
        fun onUnityGlassesModel(modelName: String?) {
            reportedGlassesModel = modelName
        }
    }
}

private class MethodChannelStartReply(
    private val result: MethodChannel.Result,
) : StartReply {
    override fun success() = result.success(null)

    override fun error(code: String, message: String) = result.error(code, message, null)
}
