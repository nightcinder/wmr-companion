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
    const val USB_PERMISSION_DENIED = "usbPermissionDenied"
}

/** A USB device as seen by [VendorDetector]; Android-free for JVM tests. */
data class UsbDeviceId(val vendorId: Int, val productId: Int)

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
