package com.onyxlens.wmr_companion_hid_android

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.ArgumentCaptor
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.anyInt
import org.mockito.ArgumentMatchers.anyString
import org.mockito.ArgumentMatchers.eq
import org.mockito.ArgumentMatchers.isNull
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Drives the plugin's method-call routing, permission callbacks and
 * activity-detach cancellation on a Robolectric main looper. Android's
 * Bluetooth stack is replaced with Mockito doubles; the plugin itself runs
 * unchanged.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class WmrCompanionHidPluginTest {
    private companion object {
        val DESCRIPTOR = byteArrayOf(0x05, 0x01, 0x09, 0x05)
        const val HOST_ADDRESS = "AA:BB:CC:DD:EE:FF"
        const val START_PERMISSION_CODE = 4711
        const val DISCOVERABLE_PERMISSION_CODE = 4712
    }

    private class RecordingResult : MethodChannel.Result {
        var succeeded = false
        var successValue: Any? = null
        var errorCode: String? = null
        var errorMessage: String? = null
        var errorDetails: Any? = null
        var notImplemented = false

        override fun success(result: Any?) {
            succeeded = true
            successValue = result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            this.errorCode = errorCode
            this.errorMessage = errorMessage
            this.errorDetails = errorDetails
        }

        override fun notImplemented() {
            notImplemented = true
        }
    }

    private class RecordingSink : EventChannel.EventSink {
        val events = mutableListOf<Any?>()

        override fun success(event: Any?) {
            events += event
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            events += mapOf(
                "state" to "error",
                "message" to errorMessage,
            )
        }

        override fun endOfStream() = Unit
    }

    private lateinit var activity: Activity
    private lateinit var binding: ActivityPluginBinding
    private lateinit var adapter: BluetoothAdapter
    private lateinit var hid: BluetoothHidDevice
    private lateinit var host: BluetoothDevice
    private lateinit var plugin: WmrCompanionHidPlugin
    private lateinit var sink: RecordingSink
    private var hidCallback: BluetoothHidDevice.Callback? = null

    @Before
    fun setUp() {
        activity = mock(Activity::class.java)
        binding = mock(ActivityPluginBinding::class.java)
        adapter = mock(BluetoothAdapter::class.java)
        hid = mock(BluetoothHidDevice::class.java)
        host = mock(BluetoothDevice::class.java)
        sink = RecordingSink()

        val manager = mock(BluetoothManager::class.java)
        `when`(activity.getSystemService(Context.BLUETOOTH_SERVICE)).thenReturn(manager)
        `when`(manager.adapter).thenReturn(adapter)
        `when`(activity.checkSelfPermission(anyString()))
            .thenReturn(PackageManager.PERMISSION_GRANTED)
        `when`(binding.activity).thenReturn(activity)
        `when`(adapter.isEnabled).thenReturn(true)
        `when`(adapter.bondedDevices).thenReturn(emptySet())
        `when`(adapter.getRemoteDevice(HOST_ADDRESS)).thenReturn(host)
        `when`(host.name).thenReturn("WMR Host")
        `when`(host.address).thenReturn(HOST_ADDRESS)

        stubHidProfile()

        plugin = WmrCompanionHidPlugin()
        plugin.onAttachedToActivity(binding)
    }

    private fun stubHidProfile(available: Boolean = true) {
        `when`(adapter.getProfileProxy(any(), any(), eq(BluetoothProfile.HID_DEVICE)))
            .thenAnswer { invocation ->
                if (available) {
                    val listener = invocation.getArgument<BluetoothProfile.ServiceListener>(1)
                    listener.onServiceConnected(BluetoothProfile.HID_DEVICE, hid)
                }
                available
            }
        `when`(
            hid.registerApp(
                any(BluetoothHidDeviceAppSdpSettings::class.java),
                isNull(),
                isNull(),
                any(Executor::class.java),
                any(BluetoothHidDevice.Callback::class.java),
            ),
        ).thenAnswer { invocation ->
            hidCallback = invocation.getArgument(4)
            true
        }
    }

    private fun idle() {
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun startPlugin(): RecordingResult {
        val result = RecordingResult()
        plugin.onMethodCall(MethodCall("start", mapOf("descriptor" to DESCRIPTOR)), result)
        assertTrue("start should register the HID app", result.succeeded)
        return result
    }

    private fun registerOnly() {
        requireNotNull(hidCallback).onAppStatusChanged(null, true)
        idle()
    }

    private fun connectHost() {
        val callback = requireNotNull(hidCallback)
        callback.onAppStatusChanged(host, true)
        callback.onConnectionStateChanged(host, BluetoothProfile.STATE_CONNECTED)
        idle()
    }

    private fun eventState(event: Any?): String? = (event as? Map<*, *>)?.get("state") as? String

    // --- method routing ---

    @Test
    fun pingIsAnsweredWithoutTouchingBluetooth() {
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("ping", null), result)

        assertTrue(result.succeeded)
        assertNull(result.successValue)
    }

    @Test
    fun unknownMethodsAreNotImplemented() {
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("nope", null), result)

        assertTrue(result.notImplemented)
        assertFalse(result.succeeded)
    }

    @Test
    fun startWithoutADescriptorFailsBeforeRequestingPermission() {
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("start", null), result)

        assertEquals("args", result.errorCode)
        assertEquals("descriptor missing", result.errorMessage)
        verify(activity, never()).requestPermissions(any(), anyInt())
    }

    @Test
    fun startWithoutAnActivityFails() {
        plugin.onDetachedFromActivity()
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("start", mapOf("descriptor" to DESCRIPTOR)), result)

        assertEquals("no_activity", result.errorCode)
    }

    @Test
    fun startRequestsConnectPermissionAndRegistersOnceGranted() {
        `when`(activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT))
            .thenReturn(PackageManager.PERMISSION_DENIED)
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("start", mapOf("descriptor" to DESCRIPTOR)), result)

        val permissions = ArgumentCaptor.forClass(Array<String>::class.java)
        verify(activity).requestPermissions(permissions.capture(), eq(START_PERMISSION_CODE))
        assertArrayEquals(
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
            permissions.value,
        )
        assertFalse(result.succeeded)

        assertTrue(
            plugin.onRequestPermissionsResult(
                START_PERMISSION_CODE,
                permissions.value,
                intArrayOf(PackageManager.PERMISSION_GRANTED),
            ),
        )

        assertTrue(result.succeeded)
        val sdp = ArgumentCaptor.forClass(BluetoothHidDeviceAppSdpSettings::class.java)
        verify(hid).registerApp(
            sdp.capture(),
            isNull(),
            isNull(),
            any(Executor::class.java),
            any(BluetoothHidDevice.Callback::class.java),
        )
        assertArrayEquals(DESCRIPTOR, sdp.value.descriptors)
        assertEquals("WMR Companion gamepad", sdp.value.name)
    }

    @Test
    fun deniedConnectPermissionFailsTheStartAndEmitsAnError() {
        `when`(activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT))
            .thenReturn(PackageManager.PERMISSION_DENIED)
        plugin.onListen(null, sink)
        val result = RecordingResult()
        plugin.onMethodCall(MethodCall("start", mapOf("descriptor" to DESCRIPTOR)), result)

        assertTrue(
            plugin.onRequestPermissionsResult(
                START_PERMISSION_CODE,
                arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
                intArrayOf(PackageManager.PERMISSION_DENIED),
            ),
        )
        idle()

        assertEquals("permission", result.errorCode)
        assertEquals("Bluetooth permission denied", result.errorMessage)
        assertEquals("error", eventState(sink.events.last()))
        assertEquals(
            "Bluetooth permission denied",
            (sink.events.last() as Map<*, *>)["message"],
        )
    }

    @Test
    fun startFailsWhenBluetoothIsOff() {
        `when`(adapter.isEnabled).thenReturn(false)
        plugin.onListen(null, sink)
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("start", mapOf("descriptor" to DESCRIPTOR)), result)
        idle()

        assertEquals("bluetooth", result.errorCode)
        assertEquals("Bluetooth is off", result.errorMessage)
        assertEquals("error", eventState(sink.events.last()))
    }

    @Test
    fun startFailsWhenTheHidProfileIsUnavailable() {
        stubHidProfile(available = false)
        plugin.onListen(null, sink)
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("start", mapOf("descriptor" to DESCRIPTOR)), result)
        idle()

        assertEquals("unsupported", result.errorCode)
        assertEquals("unsupported", eventState(sink.events.last()))
        assertEquals(
            "HID device profile not available on this phone",
            (sink.events.last() as Map<*, *>)["message"],
        )
    }

    @Test
    fun aSecondStartSupersedesThePendingOne() {
        `when`(activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT))
            .thenReturn(PackageManager.PERMISSION_DENIED)
        val first = RecordingResult()
        val second = RecordingResult()

        plugin.onMethodCall(MethodCall("start", mapOf("descriptor" to DESCRIPTOR)), first)
        plugin.onMethodCall(MethodCall("start", mapOf("descriptor" to DESCRIPTOR)), second)

        assertEquals("cancelled", first.errorCode)
        assertEquals("superseded", first.errorMessage)

        plugin.onRequestPermissionsResult(
            START_PERMISSION_CODE,
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
            intArrayOf(PackageManager.PERMISSION_GRANTED),
        )
        assertTrue(second.succeeded)
    }

    @Test
    fun stopDisconnectsUnregistersAndClosesTheProxy() {
        startPlugin()
        connectHost()
        plugin.onListen(null, sink)
        idle()
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("stop", null), result)
        idle()

        assertTrue(result.succeeded)
        verify(hid).disconnect(host)
        verify(hid).unregisterApp()
        verify(adapter).closeProfileProxy(BluetoothProfile.HID_DEVICE, hid)
        assertEquals("idle", eventState(sink.events.last()))
    }

    @Test
    fun detachingFromTheEngineStopsTheHidProxy() {
        startPlugin()
        connectHost()

        plugin.onDetachedFromEngine(mock(FlutterPlugin.FlutterPluginBinding::class.java))

        verify(hid).disconnect(host)
        verify(hid).unregisterApp()
        verify(adapter).closeProfileProxy(BluetoothProfile.HID_DEVICE, hid)
    }

    // --- reports and hosts ---

    @Test
    fun sendReportWithoutAConnectedHostFails() {
        startPlugin()
        val result = RecordingResult()

        plugin.onMethodCall(
            MethodCall("sendReport", mapOf("id" to 1, "data" to byteArrayOf(0x01))),
            result,
        )

        assertEquals("not_connected", result.errorCode)
    }

    @Test
    fun sendReportForwardsTheReportToTheConnectedHost() {
        startPlugin()
        connectHost()
        `when`(hid.sendReport(eq(host), eq(2), any())).thenReturn(true)
        val data = byteArrayOf(0x01, 0x02, 0x03)
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("sendReport", mapOf("id" to 2, "data" to data)), result)

        assertTrue(result.succeeded)
        val captured = ArgumentCaptor.forClass(ByteArray::class.java)
        verify(hid).sendReport(eq(host), eq(2), captured.capture())
        assertArrayEquals(data, captured.value)
    }

    @Test
    fun sendReportFailureIsReported() {
        startPlugin()
        connectHost()
        `when`(hid.sendReport(eq(host), eq(1), any())).thenReturn(false)
        val result = RecordingResult()

        plugin.onMethodCall(
            MethodCall("sendReport", mapOf("id" to 1, "data" to byteArrayOf(0x01))),
            result,
        )

        assertEquals("send", result.errorCode)
    }

    @Test
    fun bondedHostsIsEmptyWithoutConnectPermission() {
        `when`(activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT))
            .thenReturn(PackageManager.PERMISSION_DENIED)
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("bondedHosts", null), result)

        assertEquals(emptyList<Map<String, String>>(), result.successValue)
    }

    @Test
    fun bondedHostsMapsNameAndAddress() {
        `when`(adapter.bondedDevices).thenReturn(setOf(host))
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("bondedHosts", null), result)

        assertEquals(
            listOf(mapOf("name" to "WMR Host", "address" to HOST_ADDRESS)),
            result.successValue,
        )
    }

    @Test
    fun connectBeforeStartFails() {
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("connect", HOST_ADDRESS), result)

        assertEquals("not_ready", result.errorCode)
    }

    @Test
    fun connectSucceedsOnceRegistered() {
        startPlugin()
        registerOnly()
        `when`(hid.connect(host)).thenReturn(true)
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("connect", HOST_ADDRESS), result)

        assertTrue(result.succeeded)
        verify(hid).connect(host)
    }

    @Test
    fun connectRefusalIsReported() {
        startPlugin()
        registerOnly()
        `when`(hid.connect(host)).thenReturn(false)
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("connect", HOST_ADDRESS), result)

        assertEquals("connect", result.errorCode)
    }

    @Test
    fun disconnectDropsTheConnectedHost() {
        startPlugin()
        connectHost()
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("disconnect", null), result)

        assertTrue(result.succeeded)
        verify(hid).disconnect(host)
    }

    @Test
    fun disconnectWithoutAHostDoesNothing() {
        startPlugin()

        plugin.onMethodCall(MethodCall("disconnect", null), RecordingResult())

        verify(hid, never()).disconnect(any())
    }

    // --- discoverable ---

    @Test
    fun requestDiscoverableWithoutAnActivityFails() {
        plugin.onDetachedFromActivity()
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("requestDiscoverable", null), result)

        assertEquals("no_activity", result.errorCode)
    }

    @Test
    fun requestDiscoverableLaunchesTheSystemPromptWhenPermitted() {
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("requestDiscoverable", null), result)

        val intent = ArgumentCaptor.forClass(Intent::class.java)
        verify(activity).startActivity(intent.capture())
        assertEquals(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE, intent.value.action)
        assertEquals(
            120,
            intent.value.getIntExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, -1),
        )
        assertTrue(result.succeeded)
    }

    @Test
    fun requestDiscoverableRequestsAdvertisePermissionWhenDenied() {
        `when`(activity.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE))
            .thenReturn(PackageManager.PERMISSION_DENIED)
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("requestDiscoverable", null), result)

        val permissions = ArgumentCaptor.forClass(Array<String>::class.java)
        verify(activity).requestPermissions(permissions.capture(), eq(DISCOVERABLE_PERMISSION_CODE))
        assertArrayEquals(
            arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE),
            permissions.value,
        )
        assertFalse(result.succeeded)

        assertTrue(
            plugin.onRequestPermissionsResult(
                DISCOVERABLE_PERMISSION_CODE,
                permissions.value,
                intArrayOf(PackageManager.PERMISSION_GRANTED),
            ),
        )

        verify(activity).startActivity(any(Intent::class.java))
        assertTrue(result.succeeded)
    }

    @Test
    fun deniedAdvertisePermissionFailsDiscoverable() {
        `when`(activity.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE))
            .thenReturn(PackageManager.PERMISSION_DENIED)
        plugin.onListen(null, sink)
        val result = RecordingResult()
        plugin.onMethodCall(MethodCall("requestDiscoverable", null), result)

        assertTrue(
            plugin.onRequestPermissionsResult(
                DISCOVERABLE_PERMISSION_CODE,
                arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE),
                intArrayOf(PackageManager.PERMISSION_DENIED),
            ),
        )
        idle()

        assertEquals("permission", result.errorCode)
        assertEquals("Bluetooth advertise permission denied", result.errorMessage)
        assertEquals("error", eventState(sink.events.last()))
    }

    @Test
    fun aSecondDiscoverableRequestSupersedesThePendingOne() {
        `when`(activity.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE))
            .thenReturn(PackageManager.PERMISSION_DENIED)
        val first = RecordingResult()
        val second = RecordingResult()

        plugin.onMethodCall(MethodCall("requestDiscoverable", null), first)
        plugin.onMethodCall(MethodCall("requestDiscoverable", null), second)

        assertEquals("cancelled", first.errorCode)
        assertEquals("superseded", first.errorMessage)

        plugin.onRequestPermissionsResult(
            DISCOVERABLE_PERMISSION_CODE,
            arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE),
            intArrayOf(PackageManager.PERMISSION_GRANTED),
        )
        assertTrue(second.succeeded)
    }

    // --- activity detach and events ---

    @Test
    fun detachingTheActivityCancelsAPendingStart() {
        `when`(activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT))
            .thenReturn(PackageManager.PERMISSION_DENIED)
        val result = RecordingResult()
        plugin.onMethodCall(MethodCall("start", mapOf("descriptor" to DESCRIPTOR)), result)

        plugin.onDetachedFromActivity()

        assertEquals("cancelled", result.errorCode)
        assertEquals("activity detached", result.errorMessage)
        verify(binding).removeRequestPermissionsResultListener(plugin)

        val afterDetach = RecordingResult()
        plugin.onMethodCall(MethodCall("start", mapOf("descriptor" to DESCRIPTOR)), afterDetach)
        assertEquals("no_activity", afterDetach.errorCode)
    }

    @Test
    fun aConfigChangeDetachCancelsAPendingDiscoverable() {
        `when`(activity.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE))
            .thenReturn(PackageManager.PERMISSION_DENIED)
        val result = RecordingResult()
        plugin.onMethodCall(MethodCall("requestDiscoverable", null), result)

        plugin.onDetachedFromActivityForConfigChanges()

        assertEquals("cancelled", result.errorCode)
        assertEquals("activity detached", result.errorMessage)
        verify(binding).removeRequestPermissionsResultListener(plugin)
    }

    @Test
    fun onListenEmitsTheCurrentStateAndLaterTransitions() {
        plugin.onListen(null, sink)
        idle()
        assertEquals("idle", eventState(sink.events.single()))

        startPlugin()
        registerOnly()
        assertEquals("registered", eventState(sink.events.last()))

        connectHost()
        val connected = sink.events.last() as Map<*, *>
        assertEquals("connected", connected["state"])
        assertEquals("WMR Host", connected["device"])
    }

    @Test
    fun onCancelStopsEmitting() {
        plugin.onListen(null, sink)
        idle()
        plugin.onCancel(null)

        startPlugin()
        registerOnly()

        assertEquals(1, sink.events.size)
        assertEquals("idle", eventState(sink.events.single()))
    }
}
