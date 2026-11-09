package com.onyxlens.wmr_tracking_dispatch

/** One USB interface's class triple, kept raw so unknown classes survive. */
data class UsbInterfaceFacts(
    val interfaceClass: Int,
    val subclass: Int,
    val protocol: Int,
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "class" to interfaceClass,
        "subclass" to subclass,
        "protocol" to protocol,
    )
}

/** One attached USB device and every interface it exposes. */
data class UsbDeviceFacts(
    val vendorId: Int,
    val productId: Int,
    val deviceName: String? = null,
    val manufacturerName: String? = null,
    val productName: String? = null,
    val interfaces: List<UsbInterfaceFacts> = emptyList(),
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "vendor_id" to vendorId,
        "product_id" to productId,
        "device_name" to deviceName,
        "manufacturer" to manufacturerName,
        "product" to productName,
        "interfaces" to interfaces.map { it.toMap() },
    )
}

/** One display the host reports, with its raw type wire name. */
data class DisplayFacts(
    val id: Int,
    val type: String,
    val name: String? = null,
    val width: Int? = null,
    val height: Int? = null,
    val refreshRateHz: Double? = null,
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "id" to id,
        "type" to type,
        "name" to name,
        "width" to width,
        "height" to height,
        "refresh_rate_hz" to refreshRateHz,
    )
}

/** One XR platform feature and whether the host reports it. */
data class XrFeatureFacts(val name: String, val present: Boolean) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "name" to name,
        "present" to present,
    )
}

/** The USB, display and XR facts one probe collected. */
data class DeviceEnvironmentFacts(
    val usbHostAvailable: Boolean,
    val usbDevices: List<UsbDeviceFacts> = emptyList(),
    val displays: List<DisplayFacts> = emptyList(),
    val xrFeatures: List<XrFeatureFacts> = emptyList(),
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "usb" to linkedMapOf(
            "host_available" to usbHostAvailable,
            "devices" to usbDevices.map { it.toMap() },
        ),
        "displays" to linkedMapOf(
            "items" to displays.map { it.toMap() },
        ),
        "xr_features" to xrFeatures.map { it.toMap() },
    )
}

/** Feature name prefixes treated as XR capabilities. */
private val XR_FEATURE_PREFIXES = listOf(
    "android.software.xr",
    "android.hardware.xr",
)

/**
 * Every XR feature the host reports, plus the known names even when absent.
 *
 * The union keeps newly shipped feature names (a headset arriving before this
 * table learns them) in the snapshot while still recording a known feature as
 * `present = false` when the host does not offer it.
 */
fun xrSystemFeatures(
    installed: Collection<String>,
    known: Collection<String> = ANDROID_XR_FEATURES,
): List<XrFeatureFacts> {
    val names = sortedSetOf<String>()
    names.addAll(known)
    names.addAll(
        installed.filter { name ->
            XR_FEATURE_PREFIXES.any { prefix -> name.startsWith(prefix) }
        },
    )
    return names.map { XrFeatureFacts(it, installed.contains(it)) }
}
