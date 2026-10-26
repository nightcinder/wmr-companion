package com.onyxlens.wmr_tracking_dispatch

/**
 * USB and host identifiers used by [VendorDetector].
 *
 * Only VITURE's USB vendor ID is published in this repository's docs
 * (`docs/TRACKING.md`, 0x35CA). VITURE product IDs and every XREAL USB ID are
 * not documented here, so they default to "any product" / "no vendor" and are
 * listed as unknown in `docs/GLASSES_DETECTION.md`. Configure them with the
 * `configureIds` method instead of guessing.
 *
 * Empty product-ID sets match any product from the configured vendor ID.
 */
data class GlassesUsbConfig(
    val vitureVendorIds: Set<Int> = setOf(VITURE_VENDOR_ID),
    val vitureProductIds: Set<Int> = emptySet(),
    val xrealVendorIds: Set<Int> = emptySet(),
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
        /** Published by VITURE (see docs/TRACKING.md). */
        const val VITURE_VENDOR_ID: Int = 0x35CA

        val DEFAULT = GlassesUsbConfig()
    }
}
