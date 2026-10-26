package com.onyxlens.wmr_tracking_xreal

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class XrealRelayContractTest {
    @Test
    fun everyUnityXrHandJointMapsToADistinctOpenXrName() {
        val unityIds = XrealUnityJoints.allUnityJointIds
        val mapped = unityIds.map { XrealUnityJoints.openXrName(it) }

        assertEquals(26, unityIds.size)
        mapped.forEach { assertNotNull(it) }
        assertEquals(26, mapped.toSet().size)
        assertEquals("wrist", XrealUnityJoints.openXrName("Wrist"))
        assertEquals("palm", XrealUnityJoints.openXrName("Palm"))
        assertEquals("indexTip", XrealUnityJoints.openXrName("IndexTip"))
        assertEquals("littleTip", XrealUnityJoints.openXrName("LittleTip"))
        assertEquals("palm", XrealUnityJoints.openXrName("palm"))
        assertNull(XrealUnityJoints.openXrName("UnknownJoint"))
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
