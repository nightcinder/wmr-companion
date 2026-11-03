package com.onyxlens.wmr_tracking_android_xr

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
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
import kotlinx.coroutines.CancellationException
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

/** A typed failure caught at one native boundary, ready for the method channel. */
internal data class AndroidXrFailure(
    val code: String,
    val message: String,
    val stage: StartStage,
)

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

    /**
     * The permission/resume gate. `Session.create` runs only when this returns
     * [StartStep.CreateSession]; see [AndroidXrStartGate].
     */
    private val startGate = AndroidXrStartGate { permission -> isPermissionGranted(permission) }

    private var resumed = false
    private var lifecycleOwner: LifecycleOwner? = null

    private val resumeObserver = LifecycleEventObserver { _, event ->
        when (event) {
            Lifecycle.Event.ON_RESUME -> onActivityResumed()
            Lifecycle.Event.ON_PAUSE -> resumed = false
            else -> Unit
        }
    }

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
        observeLifecycle(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity(reportError = true)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        observeLifecycle(binding.activity)
    }

    override fun onDetachedFromActivity() {
        detachActivity(reportError = true)
    }

    private fun detachActivity(reportError: Boolean) {
        lifecycleOwner?.lifecycle?.removeObserver(resumeObserver)
        lifecycleOwner = null
        resumed = false
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        failPendingStart()
        stopTracking(reportError)
    }

    /**
     * Tracks `ON_RESUME`/`ON_PAUSE` for the current activity. A session is never
     * created while the activity is paused, which is the state the permission
     * dialog leaves it in.
     */
    private fun observeLifecycle(activity: Activity) {
        lifecycleOwner?.lifecycle?.removeObserver(resumeObserver)
        val owner = activity as? LifecycleOwner
        if (owner == null) {
            // A host without a Lifecycle still starts when the permission
            // result arrives; the resume wait is best-effort there.
            lifecycleOwner = null
            resumed = true
            return
        }
        lifecycleOwner = owner
        resumed = owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
        owner.lifecycle.addObserver(resumeObserver)
    }

    private fun onActivityResumed() {
        resumed = true
        if (startGate.onResumed() == StartStep.CreateSession) createSession()
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
        } catch (error: Throwable) {
            return mapOf(
                "supported" to false,
                "handTracking" to false,
                "headTracking" to false,
                "handJointCount" to 0,
                "reason" to "Android XR is not available: ${describe(error)}",
            )
        }
        val handReason = handTrackingReason {
            device.isHandTrackingModeSupported(HandTrackingMode.BOTH)
        }
        val handSupported = handReason == null
        return mapOf(
            "supported" to handSupported,
            "handTracking" to handSupported,
            // No public API reports SPATIAL support ahead of configure(); the
            // start call reports a refusal as `unsupported`.
            "headTracking" to true,
            "handJointCount" to if (handSupported) HandJointType.values().size else 0,
            "reason" to handReason,
            "permissions" to mapOf(
                "camera" to permissionState(context, AndroidXrPermissions.CAMERA),
                "sceneUnderstanding" to permissionState(
                    context,
                    AndroidXrPermissions.SCENE_UNDERSTANDING_COARSE,
                ),
                "handTracking" to permissionState(context, AndroidXrPermissions.HAND_TRACKING),
                "headTracking" to permissionState(context, AndroidXrPermissions.HEAD_TRACKING),
            ),
        )
    }

    private fun permissionState(context: Context, permission: String): String =
        when (ContextCompat.checkSelfPermission(context, permission)) {
            PackageManager.PERMISSION_GRANTED -> "granted"
            else -> "missing"
        }

    private fun isPermissionGranted(permission: String): Boolean {
        val context = activity ?: appContext ?: return false
        return ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED
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
        if (activity == null) {
            reply.error(
                ERROR_UNAVAILABLE,
                "No activity to host the XR session",
                StartStage.SessionCreate.wire,
            )
            return
        }
        when (val step = startGate.begin(reply, resumed)) {
            is StartStep.RequestPermissions -> {
                val current = activity ?: return
                ActivityCompat.requestPermissions(
                    current,
                    step.permissions.toTypedArray(),
                    PERMISSION_REQUEST_CODE,
                )
            }
            StartStep.CreateSession -> createSession()
            StartStep.WaitForResume, StartStep.Done -> Unit
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        // A cancelled start resolves to Done: do not create a session for it.
        val step = startGate.onPermissionsResult(permissions, grantResults, resumed)
        if (step == StartStep.CreateSession) createSession()
        return true
    }

    /**
     * Creates and configures the session at the native boundary.
     *
     * Every call into the Jetpack XR runtime is wrapped in `Throwable` so a
     * runtime fault becomes a typed error at the stage that failed instead of
     * killing the process.
     */
    @Suppress("DEPRECATION") // The Activity overload is synchronous; the
    // CoroutineContext overload needs a suspend caller, and this plugin only
    // needs the cached session for the activity it was handed.
    private fun createSession() {
        val current = activity
        if (current == null) {
            startGate.fail(
                ERROR_UNAVAILABLE,
                "No activity to host the XR session",
                StartStage.SessionCreate.wire,
            )
            return
        }
        // The result array is not the only truth: a grant can be revoked
        // between the dialog and the resume, and a session created without it
        // is exactly the crash this gate prevents.
        val missing = AndroidXrPermissions.required.filterNot { isPermissionGranted(it) }
        if (missing.isNotEmpty()) {
            startGate.fail(
                ERROR_PERMISSION_DENIED,
                "Android XR permissions were missing at session create: " +
                    missing.joinToString(),
                StartStage.Permissions.wire,
            )
            return
        }

        val created = try {
            Session.create(current)
        } catch (error: Throwable) {
            startGate.fail(
                ERROR_UNAVAILABLE,
                "Session.create failed: ${describe(error)}",
                StartStage.SessionCreate.wire,
            )
            return
        }
        val xrSession = when (created) {
            is SessionCreateSuccess -> created.session
            is SessionCreateUnsupportedDevice -> {
                startGate.fail(
                    ERROR_UNSUPPORTED,
                    "This device does not support Android XR",
                    StartStage.SessionCreate.wire,
                )
                return
            }
            is SessionCreateApkRequired -> {
                startGate.fail(
                    ERROR_UNAVAILABLE,
                    "Android XR runtime APK required: ${created.requiredApk}",
                    StartStage.SessionCreate.wire,
                )
                return
            }
            is SessionCreateTimedOut -> {
                startGate.fail(
                    ERROR_UNAVAILABLE,
                    "Android XR session creation timed out",
                    StartStage.SessionCreate.wire,
                )
                return
            }
            is SessionCreateUnknownError -> {
                startGate.fail(
                    ERROR_UNAVAILABLE,
                    "Android XR session creation failed: ${created.errorMessage}",
                    StartStage.SessionCreate.wire,
                )
                return
            }
            else -> {
                startGate.fail(
                    ERROR_UNAVAILABLE,
                    "Android XR session creation failed",
                    StartStage.SessionCreate.wire,
                )
                return
            }
        }

        val config = try {
            Config.Builder(xrSession.config)
                .setHandTracking(HandTrackingMode.BOTH)
                .setDeviceTracking(DeviceTrackingMode.SPATIAL)
                .build()
        } catch (error: Throwable) {
            val failure = configureFailure(error)
            startGate.fail(failure.code, failure.message, failure.stage.wire)
            return
        }
        val configured = try {
            xrSession.configure(config)
        } catch (error: Throwable) {
            val failure = configureFailure(error)
            startGate.fail(failure.code, failure.message, failure.stage.wire)
            return
        }
        when (configured) {
            is SessionConfigureSuccess -> Unit
            is SessionConfigureCalibrationRequired -> {
                startGate.fail(
                    ERROR_UNSUPPORTED,
                    "XR calibration is required",
                    StartStage.SessionConfigure.wire,
                )
                return
            }
            is SessionConfigureLibraryNotLinked -> {
                startGate.fail(
                    ERROR_UNAVAILABLE,
                    "XR library not linked: ${configured.libraryName}",
                    StartStage.SessionConfigure.wire,
                )
                return
            }
            else -> {
                startGate.fail(
                    ERROR_UNSUPPORTED,
                    "DeviceTrackingMode.SPATIAL or HandTrackingMode.BOTH was refused",
                    StartStage.SessionConfigure.wire,
                )
                return
            }
        }

        session = xrSession
        head = null
        leftHand = null
        rightHand = null
        started = true
        val newScope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
        scope = newScope
        trackingJob = newScope.launch {
            launch { guardTracking { collectHead(xrSession) } }
            launch {
                guardTracking {
                    Hand.left(xrSession).state.collect { state ->
                        leftHand = handJson(xrSession, state, "left")
                        if (started) emitFrame()
                    }
                }
            }
            launch {
                guardTracking {
                    Hand.right(xrSession).state.collect { state ->
                        rightHand = handJson(xrSession, state, "right")
                        if (started) emitFrame()
                    }
                }
            }
        }
        startGate.succeed()
    }

    /**
     * Contains a native fault inside one tracking collector: the start has
     * already succeeded, so report a typed tracking-stage error and stop.
     */
    private suspend fun guardTracking(block: suspend () -> Unit) {
        try {
            block()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            trackingFailed(error)
        }
    }

    private fun trackingFailed(error: Throwable) {
        val failure = trackingFailure(error)
        // `started` is set before the collectors launch and the main dispatcher
        // runs immediately, so the first `collect()` can fault while the start
        // reply is still held. Resolve that reply at `trackingStart`; the
        // detached-activity cancel would otherwise hide the real boundary.
        if (startGate.fail(failure.code, failure.message, failure.stage.wire)) {
            stopTracking(reportError = false)
            return
        }
        if (!started) return
        eventSink?.error(failure.code, failure.message, detailsFor(failure.stage))
        stopTracking(reportError = false)
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
        } catch (_: Throwable) {
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
        startGate.cancel(ERROR_UNAVAILABLE, message)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        stopTracking(reportError = false)
    }

    internal companion object {
        const val PERMISSION_REQUEST_CODE = 0x5752
        const val ERROR_PERMISSION_DENIED = "permissionDenied"
        const val ERROR_UNSUPPORTED = "unsupported"
        const val ERROR_UNAVAILABLE = "unavailable"
        const val ERROR_CLOSED = "closed"

        /**
         * The reason hand tracking is unavailable, or null when BOTH works.
         *
         * The runtime's support probe is not trusted to answer: a fault means
         * "cannot confirm hand tracking", reported as unsupported instead of
         * taking the capability handshake down.
         */
        fun handTrackingReason(probe: () -> Boolean): String? =
            try {
                if (probe()) null else "HandTrackingMode.BOTH is unsupported"
            } catch (error: Throwable) {
                "Android XR hand tracking check failed: ${describe(error)}"
            }

        /** A `Session.configure` fault, including building the config itself. */
        fun configureFailure(error: Throwable): AndroidXrFailure = AndroidXrFailure(
            if (error is IllegalArgumentException) ERROR_UNSUPPORTED else ERROR_UNAVAILABLE,
            "Session.configure failed: ${describe(error)}",
            StartStage.SessionConfigure,
        )

        /** A tracking collector fault; it is a `trackingStart` boundary failure. */
        fun trackingFailure(error: Throwable): AndroidXrFailure = AndroidXrFailure(
            ERROR_UNAVAILABLE,
            "Android XR tracking failed: ${describe(error)}",
            StartStage.TrackingStart,
        )

        fun describe(error: Throwable): String =
            error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName

        fun detailsFor(stage: StartStage): Map<String, String> = mapOf("stage" to stage.wire)

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

    override fun error(code: String, message: String, stage: String?) =
        result.error(code, message, stage?.let { mapOf("stage" to it) })
}
