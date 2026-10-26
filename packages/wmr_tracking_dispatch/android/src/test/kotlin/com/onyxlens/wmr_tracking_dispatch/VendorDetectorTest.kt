package com.onyxlens.wmr_tracking_dispatch

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class VendorDetectorTest {
    private val vitureDevice = UsbDeviceId(GlassesUsbConfig.VITURE_VENDOR_ID, 0x1011)
    private val xrealDevice = UsbDeviceId(0x3318, 0x0424)
    private val config = GlassesUsbConfig(
        xrealVendorIds = setOf(0x3318),
        xrealProductIds = setOf(0x0424),
    )
    private val detector = VendorDetector { config }

    @Test
    fun vitureUsbDeviceIsDetected() {
        val result = detector.detect(
            GlassesEnvironment(
                manufacturer = "Google",
                model = "Pixel",
                usbDevices = listOf(vitureDevice),
            ),
        )
        assertEquals(GlassesVendor.VITURE, result.vendor)
        assertEquals(GlassesHost.PHONE, result.host)
        assertNull(result.reason)
    }

    @Test
    fun xrealUsbDeviceIsDetectedFromConfiguredIds() {
        val result = detector.detect(
            GlassesEnvironment(
                manufacturer = "Google",
                model = "Pixel",
                usbDevices = listOf(xrealDevice),
            ),
        )
        assertEquals(GlassesVendor.XREAL, result.vendor)
        assertNull(result.reason)
    }

    @Test
    fun bothVendorsFailClosedAsAmbiguous() {
        val result = detector.detect(
            GlassesEnvironment(
                manufacturer = "Google",
                model = "Pixel",
                usbDevices = listOf(vitureDevice, xrealDevice),
            ),
        )
        assertEquals(GlassesVendor.NONE, result.vendor)
        assertEquals(GlassesDetectionReason.USB_AMBIGUOUS, result.reason)
    }

    @Test
    fun neitherVendorIsNone() {
        val result = detector.detect(
            GlassesEnvironment(
                manufacturer = "Google",
                model = "Pixel",
                usbDevices = listOf(UsbDeviceId(0x1234, 0x0001)),
            ),
        )
        assertEquals(GlassesVendor.NONE, result.vendor)
        assertEquals(GlassesDetectionReason.NO_MATCH, result.reason)
    }

    @Test
    fun phoneUsbMatchWorksBeforePermissionIsGranted() {
        val result = detector.detect(
            GlassesEnvironment(
                manufacturer = "Google",
                model = "Pixel",
                usbPermissionGranted = false,
                usbDevices = listOf(UsbDeviceId(GlassesUsbConfig.VITURE_VENDOR_ID, 0x1011)),
            ),
        )
        assertEquals(GlassesVendor.VITURE, result.vendor)
        assertNull(result.reason)
        assertFalse(result.usbPermissionGranted)
    }

    @Test
    fun unrelatedDeniedDeviceDoesNotSuppressAMatch() {
        val result = detector.detect(
            GlassesEnvironment(
                manufacturer = "Google",
                model = "Pixel",
                usbPermissionGranted = false,
                usbDevices = listOf(
                    UsbDeviceId(0x1234, 0x0001, permissionGranted = false),
                    UsbDeviceId(GlassesUsbConfig.VITURE_VENDOR_ID, 0x1011, permissionGranted = true),
                ),
            ),
        )
        assertEquals(GlassesVendor.VITURE, result.vendor)
        assertTrue(result.usbPermissionGranted)
    }

    @Test
    fun productionEnvironmentMappingKeepsPerDevicePermissions() {
        val environment = glassesEnvironment(
            manufacturer = "Google",
            model = "Pixel 9",
            isAndroidXrHost = false,
            usbHostAvailable = true,
            usbDevices = listOf(
                UsbDeviceSnapshot(0x1234, 0x0001, permissionGranted = false),
                UsbDeviceSnapshot(GlassesUsbConfig.VITURE_VENDOR_ID, 0x1011, permissionGranted = false),
            ),
        )

        assertFalse(environment.usbPermissionGranted)
        assertFalse(environment.usbDevices[0].permissionGranted)
        assertFalse(environment.usbDevices[1].permissionGranted)

        val result = detector.detect(environment)
        assertEquals(GlassesVendor.VITURE, result.vendor)
        assertNull(result.reason)
        assertFalse(result.usbPermissionGranted)
    }

    @Test
    fun neckbandHostWinsWithoutUsbAccess() {
        val result = detector.detect(
            GlassesEnvironment(
                manufacturer = "VITURE",
                model = "Pro Neckband",
                usbPermissionGranted = false,
            ),
        )
        assertEquals(GlassesVendor.VITURE, result.vendor)
        assertEquals(GlassesHost.NECKBAND, result.host)
    }

    @Test
    fun beamProHostWinsOverUsbIds() {
        val result = detector.detect(
            GlassesEnvironment(
                manufacturer = "XREAL",
                model = "Beam Pro",
                usbDevices = listOf(vitureDevice),
            ),
        )
        assertEquals(GlassesVendor.XREAL, result.vendor)
        assertEquals(GlassesHost.BEAM_PRO, result.host)
    }

    @Test
    fun androidXrHostIsDetectedWithNoVendorUsbDevice() {
        val result = detector.detect(
            GlassesEnvironment(
                manufacturer = "Google",
                model = "Project Moohan",
                isAndroidXrHost = true,
            ),
        )
        assertEquals(GlassesVendor.ANDROID_XR, result.vendor)
        assertTrue(result.usbPermissionGranted)
    }

    @Test
    fun blankHostIdentityIsUnknown() {
        val result = detector.detect(GlassesEnvironment())
        assertEquals(GlassesHost.UNKNOWN, result.host)
        assertEquals(GlassesVendor.NONE, result.vendor)
    }

    @Test
    fun defaultConfigShipsOnlyThePublishedVitureVendorId() {
        assertEquals(setOf(0x35CA), GlassesUsbConfig.DEFAULT.vitureVendorIds)
        assertTrue(GlassesUsbConfig.DEFAULT.vitureProductIds.isEmpty())
        assertTrue(GlassesUsbConfig.DEFAULT.xrealVendorIds.isEmpty())
        assertTrue(GlassesUsbConfig.DEFAULT.xrealProductIds.isEmpty())
    }
}
