package com.onyxlens.wmr_tracking_android_xr

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The JVM stub of [WmrTrackingAndroidXrPlugin] cannot create a real XR session,
 * so these tests drive the handlers that run around the permission dialog:
 * a start is made pending (the field the dialog result would resolve), then
 * stop/dispose and the late permission result are exercised.
 */
class AndroidXrLifecycleTest {
    private class RecordingResult : MethodChannel.Result {
        val successes = mutableListOf<Any?>()
        val errors = mutableListOf<Pair<String, String?>>()

        override fun success(result: Any?) {
            successes.add(result)
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            errors.add(errorCode to errorMessage)
        }

        override fun notImplemented() {
            errors.add("notImplemented" to null)
        }
    }

    private fun pluginWithPendingStart(): Pair<WmrTrackingAndroidXrPlugin, RecordingResult> {
        val plugin = WmrTrackingAndroidXrPlugin()
        val result = RecordingResult()
        val field = WmrTrackingAndroidXrPlugin::class.java.getDeclaredField("pendingStart")
        field.isAccessible = true
        field.set(plugin, result)
        return plugin to result
    }

    private fun pendingStart(plugin: WmrTrackingAndroidXrPlugin): Any? {
        val field = WmrTrackingAndroidXrPlugin::class.java.getDeclaredField("pendingStart")
        field.isAccessible = true
        return field.get(plugin)
    }

    private fun latePermissionResult(plugin: WmrTrackingAndroidXrPlugin): Boolean =
        plugin.onRequestPermissionsResult(
            PERMISSION_REQUEST_CODE,
            arrayOf(PERMISSION_HAND_TRACKING, PERMISSION_HEAD_TRACKING),
            intArrayOf(0, 0), // Both granted, as the dialog would report.
        )

    private fun call(plugin: WmrTrackingAndroidXrPlugin, method: String): RecordingResult {
        val result = RecordingResult()
        plugin.onMethodCall(MethodCall(method, null), result)
        return result
    }

    @Test
    fun stopWhilePermissionPendingFailsTheStartAndMakesTheLateResultANoOp() {
        val (plugin, pending) = pluginWithPendingStart()

        call(plugin, "stop")

        assertEquals(listOf<Pair<String, String?>>("unavailable" to "Android XR start was cancelled"), pending.errors)
        assertNull(pendingStart(plugin))
        assertTrue(latePermissionResult(plugin))
        assertEquals(1, pending.errors.size)
        assertTrue(pending.successes.isEmpty())
        // stop is not terminal: start is accepted, and only fails because this
        // test plugin has no activity.
        assertEquals("unavailable", call(plugin, "start").errors.single().first)
    }

    @Test
    fun disposeWhilePermissionPendingFailsTheStartAndMakesTheLateResultANoOp() {
        val (plugin, pending) = pluginWithPendingStart()

        call(plugin, "dispose")

        assertEquals(listOf<Pair<String, String?>>("unavailable" to "Android XR start was cancelled"), pending.errors)
        assertNull(pendingStart(plugin))
        assertTrue(latePermissionResult(plugin))
        assertEquals(1, pending.errors.size)
        assertTrue(pending.successes.isEmpty())
        assertEquals("closed", call(plugin, "start").errors.single().first)
    }

    @Test
    fun capabilityHandshakeMakesAFreshSourceUsableAfterDispose() {
        val plugin = WmrTrackingAndroidXrPlugin()
        call(plugin, "dispose")
        assertEquals("closed", call(plugin, "start").errors.single().first)

        // AndroidXrTrackingSource.create() calls capabilities() first.
        call(plugin, "capabilities")

        assertEquals("unavailable", call(plugin, "start").errors.single().first)
    }

    private companion object {
        // WmrTrackingAndroidXrPlugin.PERMISSION_REQUEST_CODE.
        const val PERMISSION_REQUEST_CODE = 0x5752
        const val PERMISSION_HAND_TRACKING = "android.permission.HAND_TRACKING"
        const val PERMISSION_HEAD_TRACKING = "android.permission.HEAD_TRACKING"
    }
}
