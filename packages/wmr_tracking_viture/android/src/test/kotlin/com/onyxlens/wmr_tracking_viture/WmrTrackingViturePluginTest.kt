package com.onyxlens.wmr_tracking_viture

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

import com.onyxlens.wmr_tracking_dispatch.GlassesVendor
import com.onyxlens.wmr_tracking_dispatch.PlayerHost
import com.onyxlens.wmr_tracking_dispatch.PlayerHostResult
import com.onyxlens.wmr_tracking_dispatch.SharedUnityRuntime
import com.onyxlens.wmr_tracking_dispatch.UnityPlayerHost
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class WmrTrackingViturePluginTest {
    private class FakePlayerHost(
        override val isHosted: Boolean = true,
        private val detail: String? = null,
    ) : PlayerHost {
        var hostCalls = 0
        var releases = 0

        override fun host(activity: android.app.Activity?): PlayerHostResult {
            hostCalls += 1
            return if (isHosted) {
                PlayerHostResult(true, UnityPlayerHost.STAGE_PLAYER_HOSTED)
            } else {
                PlayerHostResult(false, UnityPlayerHost.STAGE_UNAVAILABLE, detail ?: "no player")
            }
        }

        override fun release() {
            releases += 1
        }
    }

    private fun trackedPlugin(
        bridge: VitureUnityBridge,
        runtime: SharedUnityRuntime = SharedUnityRuntime(),
        host: PlayerHost = FakePlayerHost(),
    ) = WmrTrackingViturePlugin(bridge, runtime, host)


    private class FakeBridge(
        override val isUnityAvailable: Boolean = true,
        var model: String? = null,
        private val sendSucceeds: Boolean = true,
    ) : VitureUnityBridge {
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
        val reports = mutableListOf<Map<String, Any?>>()
        val errors = mutableListOf<Pair<String, String>>()

        override fun success(report: Map<String, Any?>) {
            reports += report
        }

        override fun error(code: String, message: String) {
            errors += code to message
        }
    }

    @Test
    fun capabilitiesDefersAnUnreportedGlassesModelToTheStartHandshake() {
        val bridge = FakeBridge(isUnityAvailable = true, model = null)
        val plugin = trackedPlugin(bridge)

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
        val plugin = trackedPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(false, caps["modelReported"])
        assertEquals(true, caps["supported"])
        assertEquals(26, caps["handJointCount"])
        assertNull(caps["reason"])
    }

    @Test
    fun capabilitiesReportsUnsupportedFor3DofGlassesModel() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Pro")
        val plugin = trackedPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(true, caps["unityAvailable"])
        assertEquals(true, caps["modelReported"])
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
    fun capabilitiesFailsClosedForAReportedModelItCannotClassify() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "LumaNext")
        val plugin = trackedPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(true, caps["modelReported"])
        assertEquals(false, caps["supported"])
        assertEquals(false, caps["handTracking"])
        assertEquals("LumaNext", caps["glassesModel"])
        assertEquals(
            "VITURE hand tracking requires LumaUltra on Pro Neckband (found LumaNext)",
            caps["reason"],
        )
    }

    @Test
    fun capabilitiesReportsSupportedOnlyForLumaUltra() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "LumaUltra")
        val plugin = trackedPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(true, caps["unityAvailable"])
        assertEquals(true, caps["modelReported"])
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
    fun startUnityRelayDefersAnUnreportedGlassesModelToUnity() {
        val bridge = FakeBridge(isUnityAvailable = true, model = null)
        val plugin = trackedPlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertTrue(reply.errors.isEmpty())
        assertEquals(1, reply.reports.size)
        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"start\""))
    }

    @Test
    fun startUnityRelayFailsFor3DofGlassesModel() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Luma")
        val plugin = trackedPlugin(bridge)
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
    fun startUnityRelayRejectsAReportedModelItCannotClassify() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "LumaNext")
        val plugin = trackedPlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals("unsupported", reply.errors[0].first)
        assertEquals(
            "VITURE hand tracking requires LumaUltra on Pro Neckband (found LumaNext)",
            reply.errors[0].second,
        )
        assertTrue(bridge.sentCommands.isEmpty())
    }

    @Test
    fun startUnityRelaySucceedsForLumaUltra() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "LumaUltra")
        val plugin = trackedPlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertTrue(reply.errors.isEmpty())
        assertEquals(1, reply.reports.size)
        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"start\""))
    }

    @Test
    fun startUnityRelayReusesThePlayerOwnedByXreal() {
        var creations = 0
        val runtime = SharedUnityRuntime {
            creations += 1
            true
        }
        runtime.claim(GlassesVendor.XREAL)
        val bridge = FakeBridge(isUnityAvailable = true, model = "LumaUltra")
        val plugin = trackedPlugin(bridge, runtime)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertTrue(reply.errors.isEmpty())
        assertEquals(1, reply.reports.size)
        assertEquals(GlassesVendor.XREAL, runtime.ownerVendor)
        assertEquals(1, creations)
    }

    @Test
    fun startUnityRelayFailsWhenTheSharedPlayerIsUnavailable() {
        val runtime = SharedUnityRuntime { false }
        val bridge = FakeBridge(isUnityAvailable = true, model = "LumaUltra")
        val host = FakePlayerHost(
            isHosted = false,
            detail = "No shared UnityPlayer is linked into this build",
        )
        val plugin = trackedPlugin(bridge, runtime, host)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals("unavailable", reply.errors[0].first)
        assertTrue(bridge.sentCommands.isEmpty())
    }

    @Test
    fun unsupportedModelReleasesTheClaim() {
        val runtime = SharedUnityRuntime { true }
        val plugin = trackedPlugin(FakeBridge(model = "Pro"), runtime)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertNull(runtime.ownerVendor)
    }

    @Test
    fun failedStartCommandReleasesTheClaim() {
        val runtime = SharedUnityRuntime { true }
        val plugin = trackedPlugin(
            FakeBridge(model = "LumaUltra", sendSucceeds = false),
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
        val plugin = trackedPlugin(FakeBridge(model = "LumaUltra"), runtime)
        val reply = RecordingReply()
        plugin.startUnityRelay(reply)
        assertEquals(GlassesVendor.VITURE, runtime.ownerVendor)

        plugin.onMethodCall(MethodCall("stop", null), RecordingResult())

        assertNull(runtime.ownerVendor)

        plugin.startUnityRelay(reply)
        assertEquals(GlassesVendor.VITURE, runtime.ownerVendor)

        plugin.deliverUnityError("protocol", "bad frame")

        assertNull(runtime.ownerVendor)
    }

    @Test
    fun startHostsThePlayerAndReportsTheStageState() {
        val runtime = SharedUnityRuntime { true }
        val host = FakePlayerHost()
        val plugin = trackedPlugin(FakeBridge(model = "LumaUltra"), runtime, host)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)
        val startReport = reply.reports.single()
        assertEquals("playerHosted", startReport["stage"])
        assertEquals("unknown", startReport["stereoMode"])
        runtime.dispatchStage(
            GlassesVendor.VITURE,
            "loaderStarted",
            "singlePassInstanced",
        )

        assertEquals(1, host.hostCalls)
        val report = plugin.stageFields()
        assertEquals(true, report["playerHosted"])
        assertEquals("singlePassInstanced", report["stereoMode"])
        assertEquals("loaderStarted", report["stage"])
    }

    @Test
    fun aNewStartClearsThePreviousSessionsStage() {
        val runtime = SharedUnityRuntime { true }
        val plugin = trackedPlugin(FakeBridge(model = "LumaUltra"), runtime)
        plugin.startUnityRelay(RecordingReply())
        runtime.dispatchStage(GlassesVendor.VITURE, "firstFrame", "singlePassInstanced")

        plugin.startUnityRelay(RecordingReply())

        val caps = plugin.capabilities()
        assertEquals("playerHosted", caps["stage"])
        assertEquals("unknown", caps["stereoMode"])
    }

    @Test
    fun startFailsWithTheHostDetailWhenNoPlayerCanBeHosted() {
        val runtime = SharedUnityRuntime { true }
        val host = FakePlayerHost(
            isHosted = false,
            detail = "com.unity3d.player.UnityPlayer is not linked into this build",
        )
        val bridge = FakeBridge(model = "LumaUltra")
        val plugin = trackedPlugin(bridge, runtime, host)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals("unavailable", reply.errors[0].first)
        assertTrue(reply.errors[0].second.contains("not linked"))
        assertTrue(bridge.sentCommands.isEmpty())
        assertNull(runtime.ownerVendor)
    }

    @Test
    fun stopGivesTheDisplayBackToFlutter() {
        val host = FakePlayerHost()
        val plugin = trackedPlugin(FakeBridge(model = "LumaUltra"), host = host)
        plugin.startUnityRelay(RecordingReply())

        plugin.onMethodCall(MethodCall("stop", null), RecordingResult())

        assertEquals(1, host.releases)
    }

    @Test
    fun aUnityErrorGivesTheDisplayBackToFlutter() {
        val host = FakePlayerHost()
        val plugin = trackedPlugin(FakeBridge(model = "LumaUltra"), host = host)
        plugin.startUnityRelay(RecordingReply())

        plugin.deliverUnityError("unavailable", "loader did not start")

        assertEquals(1, host.releases)
    }

    @Test
    fun capabilitiesReportHostingAndTheLastStage() {
        val runtime = SharedUnityRuntime { true }
        val host = FakePlayerHost()
        val plugin = trackedPlugin(FakeBridge(model = "LumaUltra"), runtime, host)
        plugin.startUnityRelay(RecordingReply())
        runtime.dispatchStage(GlassesVendor.VITURE, "firstFrame", "singlePassInstanced")

        val caps = plugin.capabilities()

        assertEquals(true, caps["playerHosted"])
        assertEquals("singlePassInstanced", caps["stereoMode"])
        assertEquals("firstFrame", caps["stage"])
    }

    @Test
    fun capabilitiesReportAnUnhostedPlayerHonestly() {
        val plugin = trackedPlugin(
            FakeBridge(model = "LumaUltra"),
            host = FakePlayerHost(isHosted = false),
        )

        val caps = plugin.capabilities()

        assertEquals(false, caps["playerHosted"])
        assertEquals("unknown", caps["stereoMode"])
        assertEquals("notHosted", caps["stage"])
    }

    @Test
    fun theStartCommandIsReplayedWhenTheSceneBecomesReady() {
        val bridge = FakeBridge(model = "LumaUltra")
        val plugin = trackedPlugin(bridge)
        plugin.startUnityRelay(RecordingReply())
        assertEquals(1, bridge.sentCommands.size)

        plugin.flushPendingStart()

        assertEquals(2, bridge.sentCommands.size)
        assertEquals(bridge.sentCommands[0], bridge.sentCommands[1])
        assertTrue(bridge.sentCommands[1].contains("\"cmd\":\"start\""))

        plugin.flushPendingStart()
        assertEquals(2, bridge.sentCommands.size)
    }

    @Test
    fun aStoppedSourceDoesNotReplayTheStart() {
        val bridge = FakeBridge(model = "LumaUltra")
        val plugin = trackedPlugin(bridge)
        plugin.startUnityRelay(RecordingReply())

        plugin.onMethodCall(MethodCall("stop", null), RecordingResult())
        val sentAfterStop = bridge.sentCommands.size
        plugin.flushPendingStart()

        assertEquals(sentAfterStop, bridge.sentCommands.size)
    }
}
