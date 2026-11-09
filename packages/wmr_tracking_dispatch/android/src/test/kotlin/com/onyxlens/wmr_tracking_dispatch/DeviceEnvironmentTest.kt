package com.onyxlens.wmr_tracking_dispatch

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DeviceEnvironmentTest {
    @Test
    fun unknownUsbDisplayAndFeatureFactsSurviveSerialization() {
        val facts = DeviceEnvironmentFacts(
            usbHostAvailable = true,
            usbDevices = listOf(
                UsbDeviceFacts(
                    vendorId = 0xFFFF,
                    productId = 0xEEEE,
                    productName = "URXR One",
                    interfaces = listOf(
                        UsbInterfaceFacts(
                            interfaceClass = 0xFF,
                            subclass = 0x42,
                            protocol = 0x99,
                        ),
                    ),
                ),
            ),
            displays = listOf(
                DisplayFacts(
                    id = 7,
                    type = "type_99",
                    name = "URXR One",
                    width = 2328,
                    height = 1728,
                    refreshRateHz = 90.0,
                ),
            ),
            xrFeatures = listOf(
                XrFeatureFacts("vendor.urxr.spatial", false),
            ),
        )

        val map = facts.toMap()
        val usb = map["usb"] as Map<*, *>
        val device = (usb["devices"] as List<*>).single() as Map<*, *>
        assertEquals(0xFFFF, device["vendor_id"])
        assertEquals(0xEEEE, device["product_id"])
        assertEquals("URXR One", device["product"])
        val usbInterface = (device["interfaces"] as List<*>).single() as Map<*, *>
        assertEquals(0xFF, usbInterface["class"])
        assertEquals(0x42, usbInterface["subclass"])
        assertEquals(0x99, usbInterface["protocol"])

        val displays = map["displays"] as Map<*, *>
        val display = (displays["items"] as List<*>).single() as Map<*, *>
        assertEquals("type_99", display["type"])
        assertEquals("URXR One", display["name"])

        val feature = (map["xr_features"] as List<*>).single() as Map<*, *>
        assertEquals("vendor.urxr.spatial", feature["name"])
        assertFalse(feature["present"] as Boolean)
    }

    @Test
    fun xrFeaturesKeepKnownNamesAndAddNewOnes() {
        val features = xrSystemFeatures(
            installed = setOf(
                "android.software.xr.api.openxr",
                "vendor.urxr.spatial",
                "android.hardware.camera",
            ),
        )

        val byName = features.associateBy { it.name }
        assertTrue(byName.getValue("android.software.xr.api.openxr").present)
        assertFalse(byName.getValue("android.software.xr.api.spatial").present)
        assertTrue(byName.getValue("vendor.urxr.spatial").present)
        assertFalse(byName.containsKey("android.hardware.camera"))
    }
}
