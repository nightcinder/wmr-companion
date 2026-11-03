package com.onyxlens.wmr_tracking_viture

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VitureRelayContractTest {
    @Test
    fun onlyLumaUltraAdvertises6DofHeadAnd26JointHands() {
        val ultra = VitureGlassesModelSpec.fromSdkName("LumaUltra")
        assertTrue(ultra.head6Dof)
        assertTrue(ultra.handTracking)
        assertEquals(26, ultra.handJointCount)

        for (name in listOf("One", "OneLite", "Pro", "Pro2", "Luma", "LumaPro", "LumaCyber", "Beast")) {
            val spec = VitureGlassesModelSpec.fromSdkName(name)
            assertFalse(spec.head6Dof, "$name must not advertise 6DoF head")
            assertFalse(spec.handTracking, "$name must not advertise hand tracking")
            assertEquals(0, spec.handJointCount)
        }
    }

    @Test
    fun nullOrUnreportedGlassesModelDefaultsToUnknownSpec() {
        val nullSpec = VitureGlassesModelSpec.fromSdkName(null)
        assertEquals(VitureGlassesModelSpec.UNKNOWN, nullSpec)
        assertFalse(nullSpec.head6Dof)
        assertFalse(nullSpec.handTracking)
        assertEquals(0, nullSpec.handJointCount)
        assertEquals("Unknown", nullSpec.sdkName)

        val emptySpec = VitureGlassesModelSpec.fromSdkName("  ")
        assertEquals(VitureGlassesModelSpec.UNKNOWN, emptySpec)

        val unknownSpec = VitureGlassesModelSpec.fromSdkName("UnrecognizedModel")
        assertEquals(VitureGlassesModelSpec.UNKNOWN, unknownSpec)
    }

    @Test
    fun isReportedDistinguishesAnUnreportedModelFromAClassifiedOne() {
        assertFalse(VitureGlassesModelSpec.isReported(null))
        assertFalse(VitureGlassesModelSpec.isReported("  "))
        assertFalse(VitureGlassesModelSpec.isReported("Unknown"))
        assertTrue(VitureGlassesModelSpec.isReported("LumaUltra"))
        assertTrue(VitureGlassesModelSpec.isReported("Pro"))
        assertTrue(VitureGlassesModelSpec.isReported("LumaNext"))
    }

    @Test
    fun relayCommandsFormatValidJsonEnvelopes() {
        assertEquals(
            """{"v":1,"cmd":"start","vendor":"viture","options":{"filter_mode":"responsive","aim_sensitivity":"high"}}""",
            VitureRelayCommandBuilder.start("responsive", "high"),
        )
        assertEquals(
            """{"v":1,"cmd":"recenter","vendor":"viture"}""",
            VitureRelayCommandBuilder.recenter(),
        )
        assertEquals(
            """{"v":1,"cmd":"stop","vendor":"viture"}""",
            VitureRelayCommandBuilder.stop(),
        )
        assertEquals(
            """{"v":1,"cmd":"dispose","vendor":"viture"}""",
            VitureRelayCommandBuilder.dispose(),
        )
    }
}
