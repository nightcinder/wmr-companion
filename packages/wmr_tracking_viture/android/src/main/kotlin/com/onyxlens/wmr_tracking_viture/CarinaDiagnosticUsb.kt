package com.onyxlens.wmr_tracking_viture

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Debug-only USB hand-off for the Carina C-SDK diagnostic.
 *
 * Opens the VITURE glasses' [UsbDeviceConnection] and returns its raw fd to
 * Dart. The connection stays open until Dart closes the session, so the native
 * harness can hand the same fd to `xr_device_provider_create`.
 *
 * Nothing here runs unless the plugin has already rejected a release build and
 * the Dart flag `WMR_VITURE_CARINA_DIAG` is on.
 */
internal class CarinaDiagnosticUsb(private val context: Context) {
    private data class OpenSession(val connection: UsbDeviceConnection)

    private data class PendingOpen(
        val device: UsbDevice,
        val result: MethodChannel.Result,
    )

    private val usbManager =
        context.getSystemService(Context.USB_SERVICE) as? UsbManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val sessions = mutableMapOf<String, OpenSession>()
    private var pending: PendingOpen? = null
    private var receiverRegistered = false

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context, intent: Intent) {
            if (intent.action != ACTION_USB_PERMISSION) return
            val waiting = pending ?: return
            pending = null
            val granted =
                intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            if (!granted) {
                waiting.result.error(
                    ERROR_PERMISSION_DENIED,
                    "USB permission denied for ${deviceName(waiting.device)}",
                    null,
                )
                return
            }
            openGranted(waiting.device, waiting.result)
        }
    }

    /** Requests permission if needed and completes [result] with fd metadata. */
    fun open(result: MethodChannel.Result) {
        val manager = usbManager
        if (manager == null) {
            result.error(ERROR_UNAVAILABLE, "USB host service is unavailable", null)
            return
        }
        val device = manager.deviceList.values.firstOrNull(::isVitureDevice)
        if (device == null) {
            result.error(
                ERROR_UNAVAILABLE,
                "No VITURE glasses USB device (vendor 0x35CA) is attached",
                null,
            )
            return
        }
        if (manager.hasPermission(device)) {
            openGranted(device, result)
            return
        }
        if (pending != null) {
            result.error(
                ERROR_BUSY,
                "Another Carina diagnostic USB permission request is already pending",
                null,
            )
            return
        }
        registerReceiver()
        val waiting = PendingOpen(device, result)
        pending = waiting
        mainHandler.postDelayed({
            if (pending === waiting) {
                pending = null
                result.error(
                    ERROR_PERMISSION_DENIED,
                    "Timed out waiting for USB permission for ${deviceName(device)}",
                    null,
                )
            }
        }, PERMISSION_TIMEOUT_MS)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(context.packageName)
        manager.requestPermission(
            device,
            PendingIntent.getBroadcast(context, 0, intent, flags),
        )
    }

    /** Closes the connection that owns the fd handed to the native harness. */
    fun close(sessionId: String) {
        sessions.remove(sessionId)?.connection?.close()
    }

    /** Closes every session and unregisters the USB permission receiver. */
    fun release() {
        pending?.result?.error(
            ERROR_UNAVAILABLE,
            "VITURE plugin detached before USB permission resolved",
            null,
        )
        pending = null
        sessions.values.forEach { it.connection.close() }
        sessions.clear()
        if (receiverRegistered) {
            try {
                context.unregisterReceiver(permissionReceiver)
            } catch (_: IllegalArgumentException) {
                // Already unregistered by the platform.
            }
            receiverRegistered = false
        }
        mainHandler.removeCallbacksAndMessages(null)
    }

    private fun openGranted(device: UsbDevice, result: MethodChannel.Result) {
        val manager = usbManager
        if (manager == null) {
            result.error(ERROR_UNAVAILABLE, "USB host service is unavailable", null)
            return
        }
        val connection = try {
            manager.openDevice(device)
        } catch (error: SecurityException) {
            result.error(
                ERROR_PERMISSION_DENIED,
                "USB permission was revoked before ${deviceName(device)} opened",
                null,
            )
            return
        }
        if (connection == null) {
            result.error(
                ERROR_UNAVAILABLE,
                "Could not open ${deviceName(device)}; USB access was denied",
                null,
            )
            return
        }
        val sessionId = UUID.randomUUID().toString()
        sessions[sessionId] = OpenSession(connection)
        result.success(
            linkedMapOf(
                "session" to sessionId,
                "fd" to connection.fileDescriptor,
                "productId" to device.productId,
                "deviceName" to deviceName(device),
            ),
        )
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        ContextCompat.registerReceiver(
            context,
            permissionReceiver,
            IntentFilter(ACTION_USB_PERMISSION),
            ContextCompat.RECEIVER_EXPORTED,
        )
        receiverRegistered = true
    }

    private fun isVitureDevice(device: UsbDevice): Boolean =
        device.vendorId == VITURE_VENDOR_ID

    private fun deviceName(device: UsbDevice): String =
        device.productName?.takeIf { it.isNotBlank() }
            ?: "VITURE USB device 0x%04X".format(device.productId)

    internal companion object {
        internal const val ACTION_USB_PERMISSION =
            "com.onyxlens.wmr_tracking_viture.CARINA_USB_PERMISSION"
        internal const val VITURE_VENDOR_ID = 0x35CA
        internal const val ERROR_PERMISSION_DENIED = "permissionDenied"
        internal const val ERROR_UNAVAILABLE = "unavailable"
        internal const val ERROR_BUSY = "busy"
        private const val PERMISSION_TIMEOUT_MS = 30_000L
    }
}
