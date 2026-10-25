package com.onyxlens.wmr_tracking_android_xr

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.xr.arcore.ArDevice
import androidx.xr.arcore.Hand
import androidx.xr.arcore.HandJointType
import androidx.xr.arcore.TrackingState
import androidx.xr.runtime.Config
import androidx.xr.runtime.DeviceTrackingMode
import androidx.xr.runtime.HandTrackingMode
import androidx.xr.runtime.Session
import androidx.xr.runtime.SessionConfigureCalibrationRequired
import androidx.xr.runtime.SessionConfigureLibraryNotLinked
import androidx.xr.runtime.SessionConfigureResult
import androidx.xr.runtime.SessionConfigureSuccess
import androidx.xr.runtime.SessionCreateApkRequired
import androidx.xr.runtime.SessionCreateResult
import androidx.xr.runtime.SessionCreateSuccess
import androidx.xr.runtime.SessionCreateTimedOut
import androidx.xr.runtime.SessionCreateUnknownError
import androidx.xr.runtime.SessionCreateUnsupportedDevice
import androidx.xr.runtime.XrDevice
import androidx.xr.runtime.math.Pose
import androidx.xr.runtime.math.Quaternion
import androidx.xr.runtime.math.Vector3
import androidx.xr.scenecore.scene
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

internal object AndroidXrJoints {
    /** OpenXR joint names used by the Dart HandJoint enum. */
    fun name(type: HandJointType): String = when (type) {
        HandJointType.WRIST -> "wrist"
        HandJointType.PALM -> "palm"
        HandJointType.THUMB_METACARPAL -> "thumbMetacarpal"
        HandJointType.THUMB_PROXIMAL -> "thumbProximal"
        HandJointType.THUMB_DISTAL -> "thumbDistal"
        HandJointType.THUMB_TIP -> "thumbTip"
        HandJointType.INDEX_METACARPAL -> "indexMetacarpal"
        HandJointType.INDEX_PROXIMAL -> "indexProximal"
        HandJointType.INDEX_INTERMEDIATE -> "indexIntermediate"
        HandJointType.INDEX_DISTAL -> "indexDistal"
        HandJointType.INDEX_TIP -> "indexTip"
        HandJointType.MIDDLE_METACARPAL -> "middleMetacarpal"
        HandJointType.MIDDLE_PROXIMAL -> "middleProximal"
        HandJointType.MIDDLE_INTERMEDIATE -> "middleIntermediate"
        HandJointType.MIDDLE_DISTAL -> "middleDistal"
        HandJointType.MIDDLE_TIP -> "middleTip"
        HandJointType.RING_METACARPAL -> "ringMetacarpal"
        HandJointType.RING_PROXIMAL -> "ringProximal"
        HandJointType.RING_INTERMEDIATE -> "ringIntermediate"
        HandJointType.RING_DISTAL -> "ringDistal"
        HandJointType.RING_TIP -> "ringTip"
        HandJointType.LITTLE_METACARPAL -> "littleMetacarpal"
        HandJointType.LITTLE_PROXIMAL -> "littleProximal"
        HandJointType.LITTLE_INTERMEDIATE -> "littleIntermediate"
        HandJointType.LITTLE_DISTAL -> "littleDistal"
        HandJointType.LITTLE_TIP -> "littleTip"
    }

}

/**
 * Android XR head and 26-joint hand tracking as a Flutter plugin.
 *
 * The session is configured with [HandTrackingMode.BOTH] and
 * [DeviceTrackingMode.SPATIAL]. Frames are `TrackingFrameCodec` JSON with
 * OpenXR axes, metres, `[x, y, z, w]` quaternions and a `System.nanoTime()`
 * timestamp. Permissions, unsupported devices and a refused SPATIAL mode are
 * returned as typed method-channel errors, never as an empty stream.
 *
 * A Jetpack XR [Session] is tied to the activity that created it. Activity
 * recreation therefore stops tracking and reports `unavailable`; the Dart
 * source must start again, which is idempotent.
 */
class WmrTrackingAndroidXrPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var eventSink: EventChannel.EventSink? = null
    private val pendingStart = PendingStartGate()

    private var session: Session? = null
    private var scope: CoroutineScope? = null
    private var trackingJob: Job? = null
    private var started = false
    private var disposed = false

    private var head: JSONObject? = null
    private var leftHand: JSONObject? = null
    private var rightHand: JSONObject? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "wmr_tracking_android_xr/methods")
        events = EventChannel(binding.binaryMessenger, "wmr_tracking_android_xr/frames")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        failPendingStart()
        stopTracking(reportError = false)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        eventSink = null
        appContext = null
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
                // A late permission result must not open a session after the
                // caller stopped tracking.
                failPendingStart("Android XR tracking stopped before the start completed")
                stopTracking(reportError = false)
                result.success(null)
            }
            "dispose" -> {
                failPendingStart("Android XR tracking source was disposed before the start completed")
                stopTracking(reportError = false)
                disposed = true
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun capabilities(): Map<String, Any?> {
        // Each Dart create() is a new handshake on the shared engine. `dispose`
        // is engine-scoped, so re-arm it here; otherwise a source created after
        // `WmrCompanion.detachTrackingSource()` could never start.
        disposed = false
        val context = activity ?: appContext ?: return mapOf(
            "supported" to false,
            "handTracking" to false,
            "headTracking" to false,
            "handJointCount" to 0,
            "reason" to "no Android context",
        )
        val device = try {
            XrDevice.getCurrentDevice(context)
        } catch (error: Exception) {
            return mapOf(
                "supported" to false,
                "handTracking" to false,
                "headTracking" to false,
                "handJointCount" to 0,
                "reason" to "Android XR is not available: ${error.message}",
            )
        }
        val handSupported = device.isHandTrackingModeSupported(HandTrackingMode.BOTH)
        return mapOf(
            "supported" to handSupported,
            "handTracking" to handSupported,
            // No public API reports SPATIAL support ahead of configure(); the
            // start call reports a refusal as `unsupported`.
            "headTracking" to true,
            "handJointCount" to if (handSupported) HandJointType.values().size else 0,
            "reason" to if (handSupported) null else "HandTrackingMode.BOTH is unsupported",
            "permissions" to mapOf(
                "handTracking" to permissionState(context, PERMISSION_HAND_TRACKING),
                "headTracking" to permissionState(context, PERMISSION_HEAD_TRACKING),
            ),
        )
    }

    private fun permissionState(context: Context, permission: String): String =
        when (ContextCompat.checkSelfPermission(context, permission)) {
            PackageManager.PERMISSION_GRANTED -> "granted"
            else -> "missing"
        }

    private fun start(reply: StartReply) {
        if (disposed) {
            reply.error(ERROR_CLOSED, "Android XR tracking source has been disposed")
            return
        }
        if (started) {
            reply.success()
            return
        }
        if (pendingStart.isPending) {
            reply.error(ERROR_UNAVAILABLE, "An Android XR start is already pending")
            return
        }
        val current = activity
        if (current == null) {
            reply.error(ERROR_UNAVAILABLE, "No activity to host the XR session")
            return
        }

        val missing = arrayOf(PERMISSION_HAND_TRACKING, PERMISSION_HEAD_TRACKING)
            .filter { ContextCompat.checkSelfPermission(current, it) != PackageManager.PERMISSION_GRANTED }
            .toTypedArray()
        if (missing.isEmpty()) {
            startSession(current, reply)
            return
        }
        pendingStart.hold(reply)
        ActivityCompat.requestPermissions(current, missing, PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        // Null means stop()/dispose()/detach cancelled the start while the
        // dialog was open: do not open a session for it.
        val reply = pendingStart.resolve() ?: return true
        val denied = permissions.filterIndexed { index, _ ->
            grantResults.getOrNull(index) != PackageManager.PERMISSION_GRANTED
        }
        if (denied.isNotEmpty()) {
            reply.error(
                ERROR_PERMISSION_DENIED,
                "Android XR permissions were denied: ${denied.joinToString()}",
            )
            return true
        }
        val current = activity
        if (current == null) {
            reply.error(ERROR_UNAVAILABLE, "No activity to host the XR session")
            return true
        }
        startSession(current, reply)
        return true
    }

    @Suppress("DEPRECATION") // The Activity overload is synchronous; the
    // CoroutineContext overload needs a suspend caller, and this plugin only
    // needs the cached session for the activity it was handed.
    private fun startSession(activity: Activity, reply: StartReply) {
        val created = try {
            Session.create(activity)
        } catch (error: Exception) {
            reply.error(ERROR_UNAVAILABLE, "Session.create failed: ${error.message}")
            return
        }
        val xrSession = when (created) {
            is SessionCreateSuccess -> created.session
            is SessionCreateUnsupportedDevice -> {
                reply.error(ERROR_UNSUPPORTED, "This device does not support Android XR")
                return
            }
            is SessionCreateApkRequired -> {
                reply.error(ERROR_UNAVAILABLE, "Android XR runtime APK required: ${created.requiredApk}")
                return
            }
            is SessionCreateTimedOut -> {
                reply.error(ERROR_UNAVAILABLE, "Android XR session creation timed out")
                return
            }
            is SessionCreateUnknownError -> {
                reply.error(ERROR_UNAVAILABLE, "Android XR session creation failed: ${created.errorMessage}")
                return
            }
            else -> {
                reply.error(ERROR_UNAVAILABLE, "Android XR session creation failed")
                return
            }
        }

        val config = Config.Builder(xrSession.config)
            .setHandTracking(HandTrackingMode.BOTH)
            .setDeviceTracking(DeviceTrackingMode.SPATIAL)
            .build()
        val configured = try {
            xrSession.configure(config)
        } catch (error: Exception) {
            reply.error(ERROR_UNSUPPORTED, "Session.configure failed: ${error.message}")
            return
        }
        when (configured) {
            is SessionConfigureSuccess -> Unit
            is SessionConfigureCalibrationRequired ->
                return reply.error(ERROR_UNSUPPORTED, "XR calibration is required")
            is SessionConfigureLibraryNotLinked ->
                return reply.error(
                    ERROR_UNAVAILABLE,
                    "XR library not linked: ${configured.libraryName}",
                )
            else -> return reply.error(
                ERROR_UNSUPPORTED,
                "DeviceTrackingMode.SPATIAL or HandTrackingMode.BOTH was refused",
            )
        }

        session = xrSession
        head = null
        leftHand = null
        rightHand = null
        started = true
        val newScope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
        scope = newScope
        trackingJob = newScope.launch {
            launch { collectHead(xrSession) }
            launch {
                Hand.left(xrSession).state.collect { state ->
                    leftHand = handJson(xrSession, state, "left")
                    if (started) emitFrame()
                }
            }
            launch {
                Hand.right(xrSession).state.collect { state ->
                    rightHand = handJson(xrSession, state, "right")
                    if (started) emitFrame()
                }
            }
        }
        reply.success()
    }

    private suspend fun collectHead(xrSession: Session) {
        ArDevice.getInstance(xrSession).state.collect { state ->
            head = when (state.trackingState) {
                TrackingState.TRACKING ->
                    toActivity(xrSession, state.devicePose)?.let { poseJson(it, "high") }
                TrackingState.PAUSED ->
                    toActivity(xrSession, state.devicePose)?.let { poseJson(it, "low") }
                else -> null
            }
            if (started) emitFrame()
        }
    }

    private fun handJson(xrSession: Session, state: Hand.State, side: String): JSONObject? {
        val confidence = when (state.trackingState) {
            TrackingState.TRACKING -> "high"
            TrackingState.PAUSED -> "low"
            else -> return null
        }
        val joints = JSONObject()
        for ((type, pose) in state.handJoints) {
            // Skip a joint whose space conversion failed rather than mixing
            // perception-space and activity-space poses in one frame.
            val activityPose = toActivity(xrSession, pose) ?: continue
            joints.put(AndroidXrJoints.name(type), poseJson(activityPose, confidence))
        }
        if (joints.length() == 0) return null
        return JSONObject()
            .put("hand", side)
            .put("joints", joints)
    }

    /**
     * Converts [pose] to activity space, or null when SceneCore cannot.
     *
     * Dropping the pose keeps a frame either wholly in activity space or
     * without it; passing the perception-space pose through would report the
     * wrong space at `high` confidence.
     */
    private fun toActivity(xrSession: Session, pose: Pose): Pose? =
        try {
            xrSession.scene.perceptionSpace.transformPoseTo(pose, xrSession.scene.activitySpace)
        } catch (_: Exception) {
            null
        }

    private fun emitFrame() {
        if (!started) return
        val sink = eventSink ?: return
        val frame = JSONObject()
            .put("v", 1)
            .put("time_ns", System.nanoTime())
        head?.let { frame.put("head", it) }
        val hands = JSONObject()
        leftHand?.let { hands.put("left", it) }
        rightHand?.let { hands.put("right", it) }
        if (hands.length() > 0) frame.put("hands", hands)
        sink.success(frame.toString())
    }

    private fun stopTracking(reportError: Boolean) {
        // A permission result can still arrive after the stream is cancelled or
        // the activity is gone; never let it open a session.
        failPendingStart()
        started = false
        trackingJob?.cancel()
        trackingJob = null
        scope?.cancel()
        scope = null
        session = null
        head = null
        leftHand = null
        rightHand = null
        if (reportError) {
            eventSink?.error(ERROR_UNAVAILABLE, "Android XR activity was detached", null)
        }
    }

    private fun failPendingStart(message: String = "Android XR activity was detached") {
        pendingStart.cancel(ERROR_UNAVAILABLE, message)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        stopTracking(reportError = false)
    }

    private companion object {
        const val PERMISSION_REQUEST_CODE = 0x5752
        const val PERMISSION_HAND_TRACKING = "android.permission.HAND_TRACKING"
        const val PERMISSION_HEAD_TRACKING = "android.permission.HEAD_TRACKING"
        const val ERROR_PERMISSION_DENIED = "permissionDenied"
        const val ERROR_UNSUPPORTED = "unsupported"
        const val ERROR_UNAVAILABLE = "unavailable"
        const val ERROR_CLOSED = "closed"

        fun poseJson(pose: Pose, confidence: String): JSONObject {
            val translation = pose.translation
            val rotation: Quaternion = pose.rotation
            return JSONObject()
                .put(
                    "pose",
                    JSONObject()
                        .put("t", floatArrayJson(translation.x, translation.y, translation.z))
                        .put("q", floatArrayJson(rotation.x, rotation.y, rotation.z, rotation.w)),
                )
                .put("confidence", confidence)
        }

        fun floatArrayJson(vararg values: Float): JSONArray {
            val array = JSONArray()
            for (value in values) array.put(value.toDouble())
            return array
        }

    }
}

/** Adapts a Flutter [MethodChannel.Result] to the testable [StartReply] seam. */
private class MethodChannelStartReply(
    private val result: MethodChannel.Result,
) : StartReply {
    override fun success() = result.success(null)

    override fun error(code: String, message: String) = result.error(code, message, null)
}
