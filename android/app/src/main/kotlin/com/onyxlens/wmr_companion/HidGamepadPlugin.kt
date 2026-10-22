package com.onyxlens.wmr_companion

import android.Manifest
import android.annotation.SuppressLint
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
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The phone as a Bluetooth HID gamepad (Android 9+, `BluetoothHidDevice`).
 * Dart side: lib/hid/hid_gamepad_transport.dart. The report descriptor is in
 * lib/hid/hid_report.dart and is passed in by `start`.
 *
 * Not tested on a phone: some vendors ship without the HID device profile.
 */
class HidGamepadPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methods = MethodChannel(messenger, "wmr_companion/hid_gamepad")
    private val events = EventChannel(messenger, "wmr_companion/hid_gamepad/events")
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    private var hid: BluetoothHidDevice? = null
    private var registered = false
    private var host: BluetoothDevice? = null
    private var pendingStart: MethodChannel.Result? = null
    private var descriptor: ByteArray? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun dispose() {
        stopHid()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    // --- EventChannel ---

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        emitCurrent()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(state: String, device: String? = null, message: String? = null) {
        val m = hashMapOf<String, Any?>("state" to state)
        if (device != null) m["device"] = device
        if (message != null) m["message"] = message
        main.post { sink?.success(m) }
    }

    @SuppressLint("MissingPermission")
    private fun emitCurrent() {
        when {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.P ->
                emit("unsupported", message = "Android 9 or newer needed")
            host != null -> emit("connected", device = host?.name)
            registered -> emit("registered")
            else -> emit("idle")
        }
    }

    // --- MethodChannel ---

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "ping") {
            result.success(null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            emit("unsupported", message = "Android 9 or newer needed")
            result.error("unsupported", "Android 9 or newer needed", null)
            return
        }
        when (call.method) {
            "start" -> {
                descriptor = call.argument<ByteArray>("descriptor")
                start(result)
            }
            "stop" -> {
                stopHid()
                result.success(null)
            }
            "sendReport" -> sendReport(call.argument<Int>("id") ?: 1, call.argument<ByteArray>("data"), result)
            "bondedHosts" -> bondedHosts(result)
            "connect" -> connect(call.arguments as? String, result)
            "disconnect" -> {
                disconnect()
                result.success(null)
            }
            "requestDiscoverable" -> {
                val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE)
                    .putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 120)
                activity.startActivity(intent)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun adapter(): BluetoothAdapter? =
        (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun hasConnectPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    /** Called by MainActivity for the BLUETOOTH_CONNECT request made in [start]. */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST) return
        val result = pendingStart ?: return
        pendingStart = null
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            openProxy(result)
        } else {
            emit("error", message = "Bluetooth permission denied")
            result.error("permission", "Bluetooth permission denied", null)
        }
    }

    private fun start(result: MethodChannel.Result) {
        if (descriptor == null) {
            result.error("args", "descriptor missing", null)
            return
        }
        if (!hasConnectPermission()) {
            pendingStart?.error("cancelled", "superseded", null)
            pendingStart = result
            activity.requestPermissions(
                arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
                PERMISSION_REQUEST,
            )
            return
        }
        openProxy(result)
    }

    @SuppressLint("MissingPermission")
    private fun openProxy(result: MethodChannel.Result) {
        val bt = adapter()
        if (bt == null || !bt.isEnabled) {
            emit("error", message = "Bluetooth is off")
            result.error("bluetooth", "Bluetooth is off", null)
            return
        }
        if (hid != null) {
            registerApp(hid!!, result)
            return
        }
        val ok = bt.getProfileProxy(
            activity,
            object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                    if (profile != BluetoothProfile.HID_DEVICE) return
                    hid = proxy as BluetoothHidDevice
                    registerApp(hid!!, result)
                }

                override fun onServiceDisconnected(profile: Int) {
                    if (profile != BluetoothProfile.HID_DEVICE) return
                    hid = null
                    registered = false
                    host = null
                    emit("idle")
                }
            },
            BluetoothProfile.HID_DEVICE,
        )
        if (!ok) {
            emit("unsupported", message = "HID device profile not available on this phone")
            result.error("unsupported", "HID device profile not available", null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun registerApp(proxy: BluetoothHidDevice, result: MethodChannel.Result) {
        val desc = descriptor ?: return result.error("args", "descriptor missing", null)
        val subclass = (BluetoothHidDevice.SUBCLASS1_COMBO.toInt() or
            BluetoothHidDevice.SUBCLASS2_GAMEPAD.toInt()).toByte()
        val sdp = BluetoothHidDeviceAppSdpSettings(
            "WMR Companion gamepad",
            "WMR controllers as a gamepad",
            "WMR Companion",
            subclass,
            desc,
        )
        val callback = object : BluetoothHidDevice.Callback() {
            override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, isRegistered: Boolean) {
                registered = isRegistered
                if (!isRegistered) host = null
                emitCurrent()
            }

            override fun onConnectionStateChanged(device: BluetoothDevice?, state: Int) {
                when (state) {
                    BluetoothProfile.STATE_CONNECTED -> host = device
                    BluetoothProfile.STATE_DISCONNECTED -> if (device == host) host = null
                }
                emitCurrent()
            }
        }
        val ok = proxy.registerApp(sdp, null, null, { r -> main.post(r) }, callback)
        if (ok) {
            result.success(null)
        } else {
            emit("error", message = "registerApp refused")
            result.error("register", "registerApp refused", null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopHid() {
        val proxy = hid
        if (proxy != null) {
            host?.let { proxy.disconnect(it) }
            if (registered) proxy.unregisterApp()
            adapter()?.closeProfileProxy(BluetoothProfile.HID_DEVICE, proxy)
        }
        hid = null
        registered = false
        host = null
        emitCurrent()
    }

    @SuppressLint("MissingPermission")
    private fun sendReport(id: Int, data: ByteArray?, result: MethodChannel.Result) {
        val proxy = hid
        val target = host
        if (proxy == null || target == null || data == null) {
            result.error("not_connected", "no host connected", null)
            return
        }
        if (proxy.sendReport(target, id, data)) result.success(null)
        else result.error("send", "sendReport failed", null)
    }

    @SuppressLint("MissingPermission")
    private fun bondedHosts(result: MethodChannel.Result) {
        if (!hasConnectPermission()) {
            result.success(emptyList<Map<String, String>>())
            return
        }
        val list = adapter()?.bondedDevices.orEmpty().map {
            mapOf("name" to (it.name ?: ""), "address" to it.address)
        }
        result.success(list)
    }

    @SuppressLint("MissingPermission")
    private fun connect(address: String?, result: MethodChannel.Result) {
        val proxy = hid
        val device = address?.let { adapter()?.getRemoteDevice(it) }
        if (proxy == null || !registered || device == null) {
            result.error("not_ready", "start the gamepad first", null)
            return
        }
        if (proxy.connect(device)) result.success(null)
        else result.error("connect", "connect refused", null)
    }

    @SuppressLint("MissingPermission")
    private fun disconnect() {
        val proxy = hid
        val target = host
        if (proxy != null && target != null) proxy.disconnect(target)
    }

    companion object {
        private const val PERMISSION_REQUEST = 4711
    }
}
