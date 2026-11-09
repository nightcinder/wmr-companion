package com.onyxlens.wmr_tracking_dispatch

import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.view.Display
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter entry point for pre-Unity glasses detection.
 *
 * `detectGlasses` is only called by `TrackingSourceSelector` when at least one
 * vendor flag is enabled; attaching this plugin performs no detection, so a
 * flag-off app never touches this channel.
 */
class WmrTrackingDispatchPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    @Volatile
    private var config: GlassesUsbConfig = GlassesUsbConfig.DEFAULT

    private val detector = VendorDetector { config }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(
            binding.binaryMessenger,
            CHANNEL_NAME,
        ).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "detectGlasses" -> result.success(detector.detect(environment()).toMap())
            "deviceEnvironment" -> result.success(readDeviceEnvironment())
            "configureIds" -> {
                config = configFrom(call.arguments)
                result.success(null)
            }
            "unityStatus" -> result.success(
                linkedMapOf(
                    "owner" to SharedUnityRuntime.shared.ownerVendor?.wireName,
                ),
            )
            else -> result.notImplemented()
        }
    }

    private fun environment(): GlassesEnvironment {
        val context = appContext
        if (context == null) {
            return GlassesEnvironment(
                usbPermissionGranted = false,
                isAndroidXrHost = false,
            )
        }
        val packageManager = context.packageManager
        val isAndroidXr = ANDROID_XR_FEATURES.any(packageManager::hasSystemFeature)
        val usbManager = context.getSystemService(Context.USB_SERVICE) as? UsbManager
        val devices: Collection<UsbDevice> =
            usbManager?.deviceList?.values ?: emptyList()
        return glassesEnvironment(
            manufacturer = Build.MANUFACTURER,
            model = "${Build.MODEL} ${Build.DEVICE}",
            isAndroidXrHost = isAndroidXr,
            usbHostAvailable = usbManager != null,
            usbDevices = devices.map {
                UsbDeviceSnapshot(
                    vendorId = it.vendorId,
                    productId = it.productId,
                    permissionGranted = usbManager?.hasPermission(it) == true,
                )
            },
            config = config,
        )
    }

    private fun readDeviceEnvironment(): Map<String, Any?> {
        val context = appContext
        val usbManager = context?.getSystemService(Context.USB_SERVICE) as? UsbManager
        val usbDevices = usbManager?.deviceList?.values?.map { device ->
            UsbDeviceFacts(
                vendorId = device.vendorId,
                productId = device.productId,
                deviceName = device.deviceName,
                manufacturerName = device.manufacturerName,
                productName = device.productName,
                interfaces = (0 until device.interfaceCount).map { index ->
                    val usbInterface = device.getInterface(index)
                    UsbInterfaceFacts(
                        interfaceClass = usbInterface.interfaceClass,
                        subclass = usbInterface.interfaceSubclass,
                        protocol = usbInterface.interfaceProtocol,
                    )
                },
            )
        } ?: emptyList()
        val displays = context
            ?.getSystemService(Context.DISPLAY_SERVICE)
            ?.let { it as? DisplayManager }
            ?.displays
            ?.map { display ->
                DisplayFacts(
                    id = display.displayId,
                    type = displayTypeName(display),
                    name = display.name,
                    width = display.mode?.physicalWidth,
                    height = display.mode?.physicalHeight,
                    refreshRateHz = display.mode?.refreshRate?.toDouble(),
                )
            } ?: emptyList()
        val packageManager = context?.packageManager
        val features = if (packageManager == null) {
            emptyList()
        } else {
            xrSystemFeatures(
                packageManager.systemAvailableFeatures
                    ?.mapNotNull { it.name }
                    ?: emptyList(),
                ANDROID_XR_FEATURES,
            )
        }
        return DeviceEnvironmentFacts(
            usbHostAvailable = usbManager != null,
            usbDevices = usbDevices,
            displays = displays,
            xrFeatures = features,
        ).toMap()
    }

    private fun displayTypeName(display: Display): String =
        if ((display.flags and Display.FLAG_PRESENTATION) != 0) {
            "external"
        } else {
            "builtIn"
        }

    private fun configFrom(arguments: Any?): GlassesUsbConfig {
        val args = arguments as? Map<*, *> ?: return config
        fun ids(key: String): Set<Int>? =
            (args[key] as? List<*>)?.mapNotNull { (it as? Number)?.toInt() }?.toSet()
        return GlassesUsbConfig(
            vitureVendorIds = ids("vitureVendorIds") ?: config.vitureVendorIds,
            vitureProductIds = ids("vitureProductIds") ?: config.vitureProductIds,
            xrealVendorIds = ids("xrealVendorIds") ?: config.xrealVendorIds,
            xrealProductIds = ids("xrealProductIds") ?: config.xrealProductIds,
        )
    }

    companion object {
        internal const val CHANNEL_NAME = "wmr_tracking_dispatch/methods"
    }
}
