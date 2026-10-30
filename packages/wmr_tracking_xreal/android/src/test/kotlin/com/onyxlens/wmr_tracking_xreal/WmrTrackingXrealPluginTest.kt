package com.onyxlens.wmr_tracking_xreal

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

import com.onyxlens.wmr_tracking_dispatch.GlassesVendor
import com.onyxlens.wmr_tracking_dispatch.SharedUnityRuntime
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class WmrTrackingXrealPluginTest {
    private class FakeBridge(
        override val isUnityAvailable: Boolean = true,
        var model: String? = null,
        private val sendSucceeds: Boolean = true,
    ) : XrealUnityBridge {
        val sentCommands = mutableListOf<String>()

        override fun queryGlassesModel(): String? = model

        override fun sendCommand(payloadJson: String, gameObject: String, method: String): Boolean {
            sentCommands.add(payloadJson)
            return sendSucceeds
        }
    }

    private class RecordingResult : MethodChannel.Result {
        var completed = false

        override fun success(result: Any?) {
            completed = true
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = Unit

        override fun notImplemented() = Unit
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
    fun capabilitiesDefersAnUnreportedGlassesModelToTheStartHandshake() {
        val bridge = FakeBridge(isUnityAvailable = true, model = null)
        val plugin = WmrTrackingXrealPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(true, caps["unityAvailable"])
        assertEquals(false, caps["modelReported"])
        assertEquals(true, caps["supported"])
        assertEquals(true, caps["handTracking"])
        assertEquals(true, caps["headTracking"])
        assertEquals(true, caps["handGestures"])
        assertEquals(true, caps["passthroughCamera"])
        assertEquals(26, caps["handJointCount"])
        assertEquals("Unknown", caps["glassesModel"])
        assertNull(caps["reason"])
    }

    @Test
    fun capabilitiesTreatsTheSdkUnknownPlaceholderAsUnreported() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Unknown")
        val plugin = WmrTrackingXrealPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(false, caps["modelReported"])
        assertEquals(true, caps["supported"])
        assertEquals(26, caps["handJointCount"])
        assertNull(caps["reason"])
    }

    @Test
    fun capabilitiesReportsHeadOnlyForOneSeries() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "One")
        val plugin = WmrTrackingXrealPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(true, caps["unityAvailable"])
        assertEquals(true, caps["modelReported"])
        assertEquals(false, caps["supported"])
        assertEquals(false, caps["handTracking"])
        assertEquals(true, caps["headTracking"])
        assertEquals(0, caps["handJointCount"])
        assertEquals("One", caps["glassesModel"])
        assertEquals(
            "XREAL hand tracking requires Air 2 Ultra (found One)",
            caps["reason"],
        )
    }

    @Test
    fun capabilitiesReportsUnsupportedFor3DofGlassesModel() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air2Pro")
        val plugin = WmrTrackingXrealPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(true, caps["unityAvailable"])
        assertEquals(true, caps["modelReported"])
        assertEquals(false, caps["supported"])
        assertEquals(false, caps["handTracking"])
        assertEquals(false, caps["headTracking"])
        assertEquals(0, caps["handJointCount"])
        assertEquals("Air2Pro", caps["glassesModel"])
    }

    @Test
    fun capabilitiesReportsSupportedOnlyForAir2Ultra() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air2Ultra")
        val plugin = WmrTrackingXrealPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(true, caps["unityAvailable"])
        assertEquals(true, caps["modelReported"])
        assertEquals(true, caps["supported"])
        assertEquals(true, caps["handTracking"])
        assertEquals(true, caps["headTracking"])
        assertEquals(true, caps["handGestures"])
        assertEquals(true, caps["passthroughCamera"])
        assertEquals(26, caps["handJointCount"])
        assertEquals("Air2Ultra", caps["glassesModel"])
        assertNull(caps["reason"])
    }

    @Test
    fun capabilitiesReportsUnavailableWhenUnityIsNotLinked() {
        val bridge = FakeBridge(isUnityAvailable = false, model = "Air2Ultra")
        val plugin = WmrTrackingXrealPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(false, caps["unityAvailable"])
        assertEquals(false, caps["supported"])
        assertEquals(0, caps["handJointCount"])
        assertEquals("Unknown", caps["glassesModel"])
        assertTrue((caps["reason"] as String).contains("not linked"))
    }

    @Test
    fun startUnityRelayDefersAnUnreportedGlassesModelToUnity() {
        val bridge = FakeBridge(isUnityAvailable = true, model = null)
        val plugin = WmrTrackingXrealPlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertTrue(reply.errors.isEmpty())
        assertEquals(1, reply.successes.size)
        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"start\""))
    }

    @Test
    fun startUnityRelayFailsForOneSeries() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "One")
        val plugin = WmrTrackingXrealPlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals("unsupported", reply.errors[0].first)
        assertEquals(
            "XREAL hand tracking requires Air 2 Ultra (found One)",
            reply.errors[0].second,
        )
        assertTrue(bridge.sentCommands.isEmpty())
    }

    @Test
    fun deliverUnityErrorSendsStopToUnityRelay() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air2Ultra")
        val plugin = WmrTrackingXrealPlugin(bridge)
        plugin.startUnityRelay(RecordingReply())
        bridge.sentCommands.clear()

        plugin.deliverUnityError("protocol", "malformed relay frame")

        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"stop\""))
    }

    @Test
    fun startUnityRelaySucceedsForAir2Ultra() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air2Ultra")
        val plugin = WmrTrackingXrealPlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertTrue(reply.errors.isEmpty())
        assertEquals(1, reply.successes.size)
        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"start\""))
    }

    @Test
    fun startUnityRelayReusesThePlayerOwnedByViture() {
        var creations = 0
        val runtime = SharedUnityRuntime {
            creations += 1
            true
        }
        runtime.claim(GlassesVendor.VITURE)
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air2Ultra")
        val plugin = WmrTrackingXrealPlugin(bridge, runtime)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertTrue(reply.errors.isEmpty())
        assertEquals(1, reply.successes.size)
        assertEquals(GlassesVendor.VITURE, runtime.ownerVendor)
        assertEquals(1, creations)
    }

    @Test
    fun startUnityRelayFailsWhenTheSharedPlayerIsUnavailable() {
        val runtime = SharedUnityRuntime { false }
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air2Ultra")
        val plugin = WmrTrackingXrealPlugin(bridge, runtime)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals("unavailable", reply.errors[0].first)
        assertTrue(bridge.sentCommands.isEmpty())
    }

    @Test
    fun unsupportedModelReleasesTheClaim() {
        val runtime = SharedUnityRuntime { true }
        val plugin = WmrTrackingXrealPlugin(FakeBridge(model = "One"), runtime)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertNull(runtime.ownerVendor)
    }

    @Test
    fun failedStartCommandReleasesTheClaim() {
        val runtime = SharedUnityRuntime { true }
        val plugin = WmrTrackingXrealPlugin(
            FakeBridge(model = "Air2Ultra", sendSucceeds = false),
            runtime,
        )
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertNull(runtime.ownerVendor)
    }

    @Test
    fun stopAndUnityErrorReleaseTheClaim() {
        val runtime = SharedUnityRuntime { true }
        val plugin = WmrTrackingXrealPlugin(FakeBridge(model = "Air2Ultra"), runtime)
        val reply = RecordingReply()
        plugin.startUnityRelay(reply)
        assertEquals(GlassesVendor.XREAL, runtime.ownerVendor)

        plugin.onMethodCall(MethodCall("stop", null), RecordingResult())

        assertNull(runtime.ownerVendor)

        plugin.startUnityRelay(reply)
        assertEquals(GlassesVendor.XREAL, runtime.ownerVendor)

        plugin.deliverUnityError("protocol", "bad frame")

        assertNull(runtime.ownerVendor)
    }
}
