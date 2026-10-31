package com.onyxlens.wmr_tracking_xreal

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class XrealRelayContractTest {
    @Test
    fun onlyAir2UltraAdvertises6DofHeadAnd26JointHands() {
        val ultra = XrealGlassesModelSpec.fromSdkName("Air2Ultra")
        assertTrue(ultra.head6Dof)
        assertTrue(ultra.handTracking)
        assertEquals(26, ultra.handJointCount)

        for (name in listOf("One", "OnePro")) {
            val spec = XrealGlassesModelSpec.fromSdkName(name)
            assertTrue(spec.head6Dof, "$name has 6DoF head with the XREAL Eye")
            assertFalse(spec.handTracking, "$name must not advertise hand tracking")
            assertEquals(0, spec.handJointCount)
        }

        for (name in listOf("Air", "Air2", "Air2Pro", "Light")) {
            val spec = XrealGlassesModelSpec.fromSdkName(name)
            assertFalse(spec.head6Dof, "$name must not advertise 6DoF head")
            assertFalse(spec.handTracking, "$name must not advertise hand tracking")
            assertEquals(0, spec.handJointCount)
        }
    }

    @Test
    fun deviceTypeNamesNormalizeAcrossSdkSpellings() {
        for (raw in listOf("Air2Ultra", "XREAL_AIR_2_ULTRA", "Air 2 Ultra", "air2ultra")) {
            assertEquals(
                XrealGlassesModelSpec.AIR_2_ULTRA,
                XrealGlassesModelSpec.fromSdkName(raw),
                raw,
            )
        }
        assertEquals(XrealGlassesModelSpec.ONE, XrealGlassesModelSpec.fromSdkName("XREALOne"))
        assertEquals(
            XrealGlassesModelSpec.AIR_2_PRO,
            XrealGlassesModelSpec.fromSdkName("NRAir2Pro"),
        )
    }

    @Test
    fun isReportedTreatsOnlyNullOrUnknownAsUnreported() {
        assertFalse(XrealGlassesModelSpec.isReported(null))
        assertFalse(XrealGlassesModelSpec.isReported("  "))
        assertFalse(XrealGlassesModelSpec.isReported("Unknown"))
        assertTrue(XrealGlassesModelSpec.isReported("Air2Ultra"))
        assertTrue(XrealGlassesModelSpec.isReported("Air3"))
    }

    @Test
    fun nullOrUnreportedGlassesModelDefaultsToUnknownSpec() {
        val nullSpec = XrealGlassesModelSpec.fromSdkName(null)
        assertEquals(XrealGlassesModelSpec.UNKNOWN, nullSpec)
        assertFalse(nullSpec.head6Dof)
        assertFalse(nullSpec.handTracking)
        assertEquals(0, nullSpec.handJointCount)
        assertEquals("Unknown", nullSpec.sdkName)

        val emptySpec = XrealGlassesModelSpec.fromSdkName("  ")
        assertEquals(XrealGlassesModelSpec.UNKNOWN, emptySpec)

        val unknownSpec = XrealGlassesModelSpec.fromSdkName("UnrecognizedModel")
        assertEquals(XrealGlassesModelSpec.UNKNOWN, unknownSpec)
    }

    @Test
    fun relayCommandsFormatValidJsonEnvelopes() {
        assertEquals(
            """{"v":1,"cmd":"start","vendor":"xreal"}""",
            XrealRelayCommandBuilder.start(),
        )
        assertEquals(
            """{"v":1,"cmd":"stop","vendor":"xreal"}""",
            XrealRelayCommandBuilder.stop(),
        )
        assertEquals(
            """{"v":1,"cmd":"dispose","vendor":"xreal"}""",
            XrealRelayCommandBuilder.dispose(),
        )
    }
}
