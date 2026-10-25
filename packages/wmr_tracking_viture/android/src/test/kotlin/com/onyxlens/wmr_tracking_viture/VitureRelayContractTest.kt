package com.onyxlens.wmr_tracking_viture

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class VitureRelayContractTest {
    @Test
    fun everyUnityXrHandJointMapsToADistinctOpenXrName() {
        val unityIds = VitureUnityJoints.allUnityJointIds
        val mapped = unityIds.map { VitureUnityJoints.openXrName(it) }

        assertEquals(26, unityIds.size)
        mapped.forEach { assertNotNull(it) }
        assertEquals(26, mapped.toSet().size)
        assertEquals("wrist", VitureUnityJoints.openXrName("Wrist"))
        assertEquals("palm", VitureUnityJoints.openXrName("Palm"))
        assertEquals("indexTip", VitureUnityJoints.openXrName("IndexTip"))
        assertEquals("littleTip", VitureUnityJoints.openXrName("LittleTip"))
        assertEquals("palm", VitureUnityJoints.openXrName("palm"))
        assertNull(VitureUnityJoints.openXrName("UnknownJoint"))
    }

    @Test
    fun unityToOpenXrPoseConversionMatchesSpecAndRoundTrips() {
        val pos = UnityPoseConverter.unityToOpenXrPosition(1.0, 2.0, 3.0)
        assertTrue(abs(pos[0] - 1.0) <= 1e-6)
        assertTrue(abs(pos[1] - 2.0) <= 1e-6)
        assertTrue(abs(pos[2] - (-3.0)) <= 1e-6)

        val quat = UnityPoseConverter.unityToOpenXrQuaternion(0.1, 0.2, 0.3, 0.9)
        assertTrue(abs(quat[0] - (-0.1)) <= 1e-6)
        assertTrue(abs(quat[1] - (-0.2)) <= 1e-6)
        assertTrue(abs(quat[2] - 0.3) <= 1e-6)
        assertTrue(abs(quat[3] - 0.9) <= 1e-6)

        val roundTripPos = UnityPoseConverter.openXrToUnityPosition(pos[0], pos[1], pos[2])
        val roundTripQuat = UnityPoseConverter.openXrToUnityQuaternion(
            quat[0],
            quat[1],
            quat[2],
            quat[3],
        )
        assertTrue(abs(roundTripPos[0] - 1.0) <= 1e-6)
        assertTrue(abs(roundTripPos[1] - 2.0) <= 1e-6)
        assertTrue(abs(roundTripPos[2] - 3.0) <= 1e-6)
        assertTrue(abs(roundTripQuat[0] - 0.1) <= 1e-6)
        assertTrue(abs(roundTripQuat[1] - 0.2) <= 1e-6)
        assertTrue(abs(roundTripQuat[2] - 0.3) <= 1e-6)
        assertTrue(abs(roundTripQuat[3] - 0.9) <= 1e-6)
    }

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
