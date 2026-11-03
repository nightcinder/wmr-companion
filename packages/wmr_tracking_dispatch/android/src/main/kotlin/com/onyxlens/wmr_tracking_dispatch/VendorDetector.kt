package com.onyxlens.wmr_tracking_dispatch

/**
 * Detects the glasses vendor before any Unity command is sent.
 *
 * Order, highest priority first:
 * 1. An Android XR host (`android.software.xr.api.openxr` / `.spatial`). The
 *    headset is the compute unit and runs the native Android XR tracking
 *    source. It also exposes its own USB hardware, which can match a vendor ID
 *    (Google Aura reports the XREAL-built headset as `0x3318:0x043A`), so USB
 *    detection must not treat that device as external glasses. Starting the
 *    shared vendor Unity player on an Android XR host loads VITURE's Android
 *    plugin, which crashes on the missing vendor runtime class (ONY-879).
 * 2. A known host (Neckband -> VITURE, Beam Pro -> XREAL); the host is the
 *    vendor compute unit, so its built-in glasses are already known.
 * 3. Exactly one configured USB vendor/product match. Vendor/product IDs are
 *    readable without USB permission, so matching never waits for a grant;
 *    the grant is only reported for the matched device.
 * 4. Nothing, reported as `none` with a reason.
 *
 * Both vendor USB matches fail closed instead of guessing; no Unity command is
 * sent by the caller.
 */
class VendorDetector(
    private val config: () -> GlassesUsbConfig = { GlassesUsbConfig.DEFAULT },
) {
    fun detect(environment: GlassesEnvironment): GlassesDetection {
        val ids = config()
        val host = hostOf(environment, ids)

        if (environment.isAndroidXrHost) {
            return GlassesDetection(
                vendor = GlassesVendor.ANDROID_XR,
                host = host,
                usbPermissionGranted = true,
                detail = "Android XR runtime feature reported by the host",
            )
        }

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

        val vitureDevices = environment.usbDevices.filter(ids::matchesViture)
        val xrealDevices = environment.usbDevices.filter(ids::matchesXreal)
        val viture = vitureDevices.isNotEmpty()
        val xreal = xrealDevices.isNotEmpty()

        if (viture && xreal) {
            return GlassesDetection(
                vendor = GlassesVendor.NONE,
                host = host,
                usbPermissionGranted = (vitureDevices + xrealDevices)
                    .all { it.permissionGranted },
                reason = GlassesDetectionReason.USB_AMBIGUOUS,
                detail = "Both VITURE and XREAL USB devices are attached",
            )
        }
        if (viture) {
            val granted = vitureDevices.any { it.permissionGranted }
            return GlassesDetection(
                vendor = GlassesVendor.VITURE,
                host = host,
                usbPermissionGranted = granted,
                detail = "VITURE USB vendor ID matched" +
                    if (granted) "" else " (no USB permission granted yet)",
            )
        }
        if (xreal) {
            val granted = xrealDevices.any { it.permissionGranted }
            return GlassesDetection(
                vendor = GlassesVendor.XREAL,
                host = host,
                usbPermissionGranted = granted,
                detail = "XREAL USB vendor ID matched" +
                    if (granted) "" else " (no USB permission granted yet)",
            )
        }
        return GlassesDetection(
            vendor = GlassesVendor.NONE,
            host = host,
            usbPermissionGranted = environment.usbPermissionGranted,
            reason = GlassesDetectionReason.NO_MATCH,
            detail = "No configured USB ID or host marker matched",
        )
    }

    private fun hostOf(
        environment: GlassesEnvironment,
        ids: GlassesUsbConfig,
    ): GlassesHost {
        // An Android XR headset is its own compute unit; its vendor-name
        // hardware must not label it as a Beam Pro or Neckband.
        if (environment.isAndroidXrHost) return GlassesHost.UNKNOWN
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
        return GlassesHost.PHONE
    }
}
