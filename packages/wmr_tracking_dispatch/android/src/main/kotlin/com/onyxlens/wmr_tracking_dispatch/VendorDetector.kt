package com.onyxlens.wmr_tracking_dispatch

/**
 * Detects the glasses vendor before any Unity command is sent.
 *
 * Order, highest priority first:
 * 1. A known host (Neckband -> VITURE, Beam Pro -> XREAL); the host is the
 *    vendor compute unit, so its built-in glasses are already known.
 * 2. Exactly one configured USB vendor/product match.
 * 3. An Android XR host (`android.software.xr.api.openxr` / `.spatial`).
 * 4. Nothing, reported as `none` with a reason.
 *
 * Both vendor USB matches, or unreadable USB IDs on an unknown host, fail
 * closed instead of guessing; no Unity command is sent by the caller.
 */
class VendorDetector(
    private val config: () -> GlassesUsbConfig = { GlassesUsbConfig.DEFAULT },
) {
    fun detect(environment: GlassesEnvironment): GlassesDetection {
        val ids = config()
        val host = hostOf(environment, ids)

        when (host) {
            GlassesHost.NECKBAND -> return GlassesDetection(
                vendor = GlassesVendor.VITURE,
                host = host,
                usbPermissionGranted = environment.usbPermissionGranted,
                detail = "VITURE Neckband host",
            )
            GlassesHost.BEAM_PRO -> return GlassesDetection(
                vendor = GlassesVendor.XREAL,
                host = host,
                usbPermissionGranted = environment.usbPermissionGranted,
                detail = "XREAL Beam Pro host",
            )
            else -> Unit
        }

        if (!environment.usbPermissionGranted) {
            return GlassesDetection(
                vendor = GlassesVendor.NONE,
                host = host,
                usbPermissionGranted = false,
                reason = GlassesDetectionReason.USB_PERMISSION_DENIED,
                detail = "USB access was denied; no vendor ID could be read",
            )
        }

        val viture = environment.usbDevices.any(ids::matchesViture)
        val xreal = environment.usbDevices.any(ids::matchesXreal)

        if (viture && xreal) {
            return GlassesDetection(
                vendor = GlassesVendor.NONE,
                host = host,
                usbPermissionGranted = true,
                reason = GlassesDetectionReason.USB_AMBIGUOUS,
                detail = "Both VITURE and XREAL USB devices are attached",
            )
        }
        if (viture) {
            return GlassesDetection(
                vendor = GlassesVendor.VITURE,
                host = host,
                usbPermissionGranted = true,
                detail = "VITURE USB vendor ID matched",
            )
        }
        if (xreal) {
            return GlassesDetection(
                vendor = GlassesVendor.XREAL,
                host = host,
                usbPermissionGranted = true,
                detail = "XREAL USB vendor ID matched",
            )
        }
        if (environment.isAndroidXrHost) {
            return GlassesDetection(
                vendor = GlassesVendor.ANDROID_XR,
                host = host,
                usbPermissionGranted = true,
                detail = "Android XR runtime feature reported by the host",
            )
        }
        return GlassesDetection(
            vendor = GlassesVendor.NONE,
            host = host,
            usbPermissionGranted = true,
            reason = GlassesDetectionReason.NO_MATCH,
            detail = "No configured USB ID or host marker matched",
        )
    }

    private fun hostOf(
        environment: GlassesEnvironment,
        ids: GlassesUsbConfig,
    ): GlassesHost {
        val identity = listOfNotNull(environment.manufacturer, environment.model)
            .joinToString(" ")
            .lowercase()
        if (identity.isBlank()) return GlassesHost.UNKNOWN
        if (ids.vitureHostMarkers.any { identity.contains(it.lowercase()) }) {
            return GlassesHost.NECKBAND
        }
        if (ids.xrealHostMarkers.any { identity.contains(it.lowercase()) }) {
            return GlassesHost.BEAM_PRO
        }
        return if (environment.isAndroidXrHost) {
            GlassesHost.UNKNOWN
        } else {
            GlassesHost.PHONE
        }
    }
}
