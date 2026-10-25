package com.onyxlens.wmr_tracking_viture

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WmrTrackingViturePluginTest {
    private class FakeBridge(
        override val isUnityAvailable: Boolean = true,
        var model: String? = null,
    ) : VitureUnityBridge {
        val sentCommands = mutableListOf<String>()

        override fun queryGlassesModel(): String? = model

        override fun sendCommand(payloadJson: String, gameObject: String, method: String): Boolean {
            sentCommands.add(payloadJson)
            return true
        }
    }

    private class RecordingReply : StartReply {
        val successes = mutableListOf<Unit>()
        val errors = mutableListOf<Pair<String, String>>()

        override fun success() {
            successes += Unit
        }

        override fun error(code: String, message: String) {
            errors += code to message
        }
    }

    @Test
    fun capabilitiesReportsUnsupportedWhenGlassesModelIsNull() {
        val bridge = FakeBridge(isUnityAvailable = true, model = null)
        val plugin = WmrTrackingViturePlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(true, caps["unityAvailable"])
        assertEquals(false, caps["supported"])
        assertEquals(false, caps["handTracking"])
        assertEquals(false, caps["headTracking"])
        assertEquals(false, caps["handGestures"])
        assertEquals(false, caps["passthroughCamera"])
        assertEquals(0, caps["handJointCount"])
        assertEquals("Unknown", caps["glassesModel"])
        assertEquals(
            "VITURE hand tracking requires LumaUltra on Pro Neckband (found Unknown)",
            caps["reason"],
        )
    }

    @Test
    fun capabilitiesReportsUnsupportedFor3DofGlassesModel() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Pro")
        val plugin = WmrTrackingViturePlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(true, caps["unityAvailable"])
        assertEquals(false, caps["supported"])
        assertEquals(false, caps["handTracking"])
        assertEquals(false, caps["headTracking"])
        assertEquals(0, caps["handJointCount"])
        assertEquals("Pro", caps["glassesModel"])
        assertEquals(
            "VITURE hand tracking requires LumaUltra on Pro Neckband (found Pro)",
            caps["reason"],
        )
    }

    @Test
    fun capabilitiesReportsSupportedOnlyForLumaUltra() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "LumaUltra")
        val plugin = WmrTrackingViturePlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(true, caps["unityAvailable"])
        assertEquals(true, caps["supported"])
        assertEquals(true, caps["handTracking"])
        assertEquals(true, caps["headTracking"])
        assertEquals(true, caps["handGestures"])
        assertEquals(true, caps["passthroughCamera"])
        assertEquals(26, caps["handJointCount"])
        assertEquals("LumaUltra", caps["glassesModel"])
        assertNull(caps["reason"])
    }

    @Test
    fun startUnityRelayFailsWhenGlassesModelIsNull() {
        val bridge = FakeBridge(isUnityAvailable = true, model = null)
        val plugin = WmrTrackingViturePlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals("unsupported", reply.errors[0].first)
        assertEquals(
            "VITURE hand tracking requires LumaUltra on Pro Neckband (found Unknown)",
            reply.errors[0].second,
        )
        assertTrue(bridge.sentCommands.isEmpty())
    }

    @Test
    fun startUnityRelayFailsFor3DofGlassesModel() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Luma")
        val plugin = WmrTrackingViturePlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals("unsupported", reply.errors[0].first)
        assertEquals(
            "VITURE hand tracking requires LumaUltra on Pro Neckband (found Luma)",
            reply.errors[0].second,
        )
        assertTrue(bridge.sentCommands.isEmpty())
    }

    @Test
    fun startUnityRelaySucceedsForLumaUltra() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "LumaUltra")
        val plugin = WmrTrackingViturePlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertTrue(reply.errors.isEmpty())
        assertEquals(1, reply.successes.size)
        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"start\""))
    }
}
