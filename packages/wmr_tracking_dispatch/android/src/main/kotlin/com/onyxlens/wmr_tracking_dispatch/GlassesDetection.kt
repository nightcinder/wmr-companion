package com.onyxlens.wmr_tracking_dispatch

/** A vendor identified before any Unity command is sent. */
enum class GlassesVendor(val wireName: String) {
    VITURE("viture"),
    XREAL("xreal"),
    ANDROID_XR("androidXr"),
    NONE("none"),
}

/** The Android host the app runs on. */
enum class GlassesHost(val wireName: String) {
    NECKBAND("neckband"),
    BEAM_PRO("beamPro"),
    PHONE("phone"),
    UNKNOWN("unknown"),
}

/** Why detection did not produce a vendor. */
object GlassesDetectionReason {
    const val NO_MATCH = "noMatch"
    const val USB_AMBIGUOUS = "usbAmbiguous"
}

/** A USB device as seen by [VendorDetector]; Android-free for JVM tests. */
data class UsbDeviceId(
    val vendorId: Int,
    val productId: Int,
    /** Whether the app may open it; IDs are readable without this grant. */
    val permissionGranted: Boolean = false,
)

/** Raw Android USB facts before they become a [GlassesEnvironment]. */
data class UsbDeviceSnapshot(
    val vendorId: Int,
    val productId: Int,
    val permissionGranted: Boolean,
)

/**
 * Production mapping from Android USB facts to [GlassesEnvironment].
 *
 * Kept separate from `Build`/`UsbManager` so the JVM tests exercise the same
 * per-device permission mapping the plugin uses.
 */
fun glassesEnvironment(
    manufacturer: String?,
    model: String?,
    isAndroidXrHost: Boolean,
    usbHostAvailable: Boolean,
    usbDevices: List<UsbDeviceSnapshot>,
    config: GlassesUsbConfig = GlassesUsbConfig.DEFAULT,
): GlassesEnvironment {
    val devices = usbDevices.map {
        UsbDeviceId(it.vendorId, it.productId, it.permissionGranted)
    }
    return GlassesEnvironment(
        manufacturer = manufacturer,
        model = model,
        isAndroidXrHost = isAndroidXrHost,
        // Same "at least one relevant device is openable" rule the detector
        // uses for a matched vendor; `all` would let one unrelated denied
        // device mask a granted glasses device in the host/no-match fallback
        // paths, and `any` over every device would let a granted keyboard or
        // hub report USB permission for glasses that are not granted.
        usbPermissionGranted = usbHostAvailable && devices.any {
            (config.matchesViture(it) || config.matchesXreal(it)) && it.permissionGranted
        },
        usbDevices = devices,
    )
}

/**
 * The inputs the detector inspects. Production fills this from `Build`,
 * `PackageManager` and `UsbManager`; tests use fakes.
 */
data class GlassesEnvironment(
    val manufacturer: String? = null,
    val model: String? = null,
    val isAndroidXrHost: Boolean = false,
    val usbPermissionGranted: Boolean = true,
    val usbDevices: List<UsbDeviceId> = emptyList(),
)

/** The typed result sent to Dart as a map. */
data class GlassesDetection(
    val vendor: GlassesVendor,
    val host: GlassesHost,
    val usbPermissionGranted: Boolean,
    val reason: String? = null,
    val detail: String? = null,
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "vendor" to vendor.wireName,
        "host" to host.wireName,
        "usbPermissionGranted" to usbPermissionGranted,
        "reason" to reason,
        "detail" to detail,
    )
}
