package com.onyxlens.wmr_tracking_dispatch

/**
 * USB and host identifiers used by [VendorDetector].
 *
 * VITURE and XREAL USB vendor IDs are the published values (0x35CA and
 * 0x3318). Product IDs are not documented here, so they default to "any
 * product" and are listed as unknown in `docs/GLASSES_DETECTION.md`.
 * Configure them with the `configureIds` method instead of guessing.
 *
 * Empty product-ID sets match any product from the configured vendor ID.
 */
data class GlassesUsbConfig(
    val vitureVendorIds: Set<Int> = setOf(VITURE_VENDOR_ID),
    val vitureProductIds: Set<Int> = emptySet(),
    val xrealVendorIds: Set<Int> = setOf(XREAL_VENDOR_ID),
    val xrealProductIds: Set<Int> = emptySet(),
    val vitureHostMarkers: Set<String> = setOf("viture"),
    val xrealHostMarkers: Set<String> = setOf("xreal", "nreal"),
) {
    fun matchesViture(device: UsbDeviceId): Boolean =
        device.vendorId in vitureVendorIds &&
            (vitureProductIds.isEmpty() || device.productId in vitureProductIds)

    fun matchesXreal(device: UsbDeviceId): Boolean =
        device.vendorId in xrealVendorIds &&
            (xrealProductIds.isEmpty() || device.productId in xrealProductIds)

    companion object {
        /** Published by VITURE (see docs/GLASSES_DETECTION.md). */
        const val VITURE_VENDOR_ID: Int = 0x35CA

        /** Published by XREAL (see docs/GLASSES_DETECTION.md). */
        const val XREAL_VENDOR_ID: Int = 0x3318

        val DEFAULT = GlassesUsbConfig()
    }
}
