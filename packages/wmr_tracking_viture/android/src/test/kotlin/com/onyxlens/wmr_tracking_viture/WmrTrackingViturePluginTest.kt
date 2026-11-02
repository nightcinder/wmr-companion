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
import com.onyxlens.wmr_tracking_dispatch.StartCommandDispatch
import com.onyxlens.wmr_tracking_dispatch.UnityPlayerHost
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class WmrTrackingViturePluginTest {
    private class FakePlayerHost(
        override val isHosted: Boolean = true,
        private val detail: String? = null,
        private val throwOnHost: Boolean = false,
    ) : PlayerHost {
        var hostCalls = 0
        var releases = 0

        override fun host(activity: android.app.Activity?): PlayerHostResult {
            hostCalls += 1
            if (throwOnHost) throw IllegalStateException("host exploded")
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
        var errorCode: String? = null
        var errorDetails: Any? = null

        override fun success(result: Any?) {
            completed = true
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            this.errorCode = errorCode
            this.errorDetails = errorDetails
        }

        override fun notImplemented() = Unit
    }

    private class RecordingReply : StartReply {
        val reports = mutableListOf<Map<String, Any?>>()
        val errors = mutableListOf<Triple<String, String, String?>>()

        override fun success(report: Map<String, Any?>) {
            reports += report
        }

        override fun error(code: String, message: String, stage: String?) {
            errors += Triple(code, message, stage)
        }
    }

    private class ThrowingBridge(
        private val throwOnModel: Boolean = true,
        private val throwOnSend: Boolean = false,
    ) : VitureUnityBridge {
        override val isUnityAvailable: Boolean = true

        override fun queryGlassesModel(): String? {
            if (throwOnModel) throw IllegalStateException("model query failed")
            return "LumaUltra"
        }

        override fun sendCommand(payloadJson: String, gameObject: String, method: String): Boolean {
            if (throwOnSend) throw IllegalStateException("host command failed")
            return true
        }
    }

    private class RecordingSink : io.flutter.plugin.common.EventChannel.EventSink {
        val events = mutableListOf<Any?>()
        val errors = mutableListOf<Triple<String, String?, Any?>>()

        override fun success(event: Any?) {
            events += event
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            errors += Triple(errorCode, errorMessage, errorDetails)
        }

        override fun endOfStream() = Unit
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
        assertEquals(0, bridge.sentCommands.size)
        assertEquals(StartCommandDispatch.SENT, plugin.flushPendingStart())
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
        // A cold player is still initialising: no UnitySendMessage yet.
        assertTrue(bridge.sentCommands.isEmpty())

        assertEquals(StartCommandDispatch.SENT, plugin.flushPendingStart())

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
        runtime.dispatchStage(GlassesVendor.VITURE, UnityPlayerHost.STAGE_PLAYER_HOSTED, null)
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
        assertEquals(0, bridge.sentCommands.size)

        assertEquals(StartCommandDispatch.SENT, plugin.flushPendingStart())

        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"start\""))

        plugin.flushPendingStart()
        assertEquals(1, bridge.sentCommands.size)
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

    @Test
    fun stopWhileTheStartIsQueuedSendsNothingToUnity() {
        val bridge = FakeBridge(model = "LumaUltra")
        val runtime = SharedUnityRuntime { true }
        val plugin = trackedPlugin(bridge, runtime)
        plugin.startUnityRelay(RecordingReply())

        plugin.onMethodCall(MethodCall("stop", null), RecordingResult())

        assertTrue(bridge.sentCommands.isEmpty())
        assertNull(runtime.ownerVendor)
        assertEquals(StartCommandDispatch.NONE, plugin.flushPendingStart())
    }

    @Test
    fun disposeWhileTheStartIsQueuedSendsNothingToUnity() {
        val bridge = FakeBridge(model = "LumaUltra")
        val runtime = SharedUnityRuntime { true }
        val plugin = trackedPlugin(bridge, runtime)
        plugin.startUnityRelay(RecordingReply())

        plugin.onMethodCall(MethodCall("dispose", null), RecordingResult())

        assertTrue(bridge.sentCommands.isEmpty())
        assertNull(runtime.ownerVendor)
    }

    @Test
    fun stopAfterAHostedStartSendsStopToUnity() {
        val bridge = FakeBridge(model = "LumaUltra")
        val runtime = SharedUnityRuntime { true }
        val plugin = trackedPlugin(bridge, runtime)
        plugin.startUnityRelay(RecordingReply())
        plugin.deliverUnityStage(UnityPlayerHost.STAGE_PLAYER_HOSTED, null)
        bridge.sentCommands.clear()

        plugin.onMethodCall(MethodCall("stop", null), RecordingResult())

        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"stop\""))
    }

    @Test
    fun aRefusedReplayFailsTheQueuedSession() {
        val runtime = SharedUnityRuntime { true }
        val host = FakePlayerHost()
        val plugin = trackedPlugin(
            FakeBridge(model = "LumaUltra", sendSucceeds = false),
            runtime,
            host,
        )
        val sink = RecordingSink()
        plugin.onListen(null, sink)
        val reply = RecordingReply()
        plugin.startUnityRelay(reply)
        assertTrue(reply.errors.isEmpty())
        assertEquals(1, reply.reports.size)

        plugin.deliverUnityStage(UnityPlayerHost.STAGE_PLAYER_HOSTED, null)

        assertEquals("unavailable", sink.errors.single().first)
        val details = sink.errors.single().third as Map<*, *>
        assertEquals(com.onyxlens.wmr_tracking_dispatch.TrackingStartStage.COMMAND, details["stage"])
        assertNull(runtime.ownerVendor)
        assertEquals(1, host.releases)
        assertEquals(StartCommandDispatch.NONE, plugin.flushPendingStart())
    }

    @Test
    fun startErrorsCarryTheFailingStage() {
        val host = FakePlayerHost(isHosted = false, detail = "player failed")
        val plugin = trackedPlugin(FakeBridge(model = "LumaUltra"), host = host)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals("unavailable", reply.errors.single().first)
        assertEquals(UnityPlayerHost.STAGE_UNAVAILABLE, reply.errors.single().third)
    }

    @Test
    fun modelRejectionReportsTheModelStage() {
        val plugin = trackedPlugin(FakeBridge(model = "Luma"))
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals("unsupported", reply.errors.single().first)
        assertEquals(
            com.onyxlens.wmr_tracking_dispatch.TrackingStartStage.MODEL,
            reply.errors.single().third,
        )
    }

    @Test
    fun aThrowingBridgeFailsTheStartExactlyOnceAndReleasesThePlayer() {
        val host = FakePlayerHost()
        val plugin = trackedPlugin(ThrowingBridge(), host = host)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals(
            com.onyxlens.wmr_tracking_dispatch.TrackingStartStage.START_FAILED,
            reply.errors.single().third,
        )
        assertEquals(1, host.releases)
    }

    @Test
    fun aThrowingStartCommandFailsTheStartAndReleasesTheClaim() {
        val runtime = SharedUnityRuntime { true }
        runtime.dispatchStage(GlassesVendor.VITURE, UnityPlayerHost.STAGE_PLAYER_HOSTED, null)
        val host = FakePlayerHost()
        val plugin = trackedPlugin(
            ThrowingBridge(throwOnModel = false, throwOnSend = true),
            runtime,
            host,
        )
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals(
            com.onyxlens.wmr_tracking_dispatch.TrackingStartStage.START_FAILED,
            reply.errors.single().third,
        )
        assertNull(runtime.ownerVendor)
        assertEquals(1, host.releases)
    }

    @Test
    fun aUnityErrorStopsTheRelayBeforeDetaching() {
        val bridge = FakeBridge(model = "LumaUltra")
        val plugin = trackedPlugin(bridge)
        val sink = RecordingSink()
        plugin.onListen(null, sink)
        plugin.startUnityRelay(RecordingReply())
        bridge.sentCommands.clear()

        plugin.deliverUnityError("unavailable", "loader did not start")

        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands.single().contains("\"cmd\":\"stop\""))
        val details = sink.errors.single().third as Map<*, *>
        assertEquals(
            com.onyxlens.wmr_tracking_dispatch.TrackingStartStage.RUNTIME,
            details["stage"],
        )
    }

    @Test
    fun aDeniedPermissionFailsTheHeldStartWithThePermissionStage() {
        val plugin = trackedPlugin(FakeBridge(model = "LumaUltra"))
        val reply = RecordingReply()
        assertTrue(plugin.pendingStart.hold(reply))

        val handled = plugin.onRequestPermissionsResult(
            WmrTrackingViturePlugin.PERMISSION_REQUEST_CODE,
            arrayOf(WmrTrackingViturePlugin.PERMISSION_CAMERA),
            intArrayOf(android.content.pm.PackageManager.PERMISSION_DENIED),
        )

        assertTrue(handled)
        assertEquals("permissionDenied", reply.errors.single().first)
        assertEquals(
            com.onyxlens.wmr_tracking_dispatch.TrackingStartStage.PERMISSION,
            reply.errors.single().third,
        )
    }

    @Test
    fun stopWhilePermissionIsPendingFailsTheHeldStartWithThePendingStage() {
        val plugin = trackedPlugin(FakeBridge(model = "LumaUltra"))
        val reply = RecordingReply()
        assertTrue(plugin.pendingStart.hold(reply))

        plugin.onMethodCall(MethodCall("stop", null), RecordingResult())

        assertEquals("unavailable", reply.errors.single().first)
        assertEquals(
            com.onyxlens.wmr_tracking_dispatch.TrackingStartStage.PENDING,
            reply.errors.single().third,
        )
    }

    @Test
    fun theRigsStageReportReachesTheVendorThatOwnsTheRuntime() {
        val runtime = SharedUnityRuntime.shared
        val recorder = RecordingHandler()
        runtime.register(GlassesVendor.XREAL, recorder)
        try {
            runtime.claim(GlassesVendor.XREAL) { true }

            WmrTrackingViturePlugin.onUnityStage("playerHosted", "singlePassInstanced")

            assertEquals(
                listOf<Pair<String, String?>>("playerHosted" to "singlePassInstanced"),
                recorder.stages,
            )
            assertEquals("playerHosted", runtime.stage(GlassesVendor.XREAL)?.stage)
            assertNull(runtime.stage(GlassesVendor.VITURE))
        } finally {
            runtime.unregister(GlassesVendor.XREAL, recorder)
            runtime.release(GlassesVendor.XREAL)
            runtime.clearStage(GlassesVendor.XREAL)
            runtime.clearStage(GlassesVendor.VITURE)
        }
    }

    private class RecordingHandler : SharedUnityRuntime.Handler {
        val stages = mutableListOf<Pair<String, String?>>()

        override fun onFrame(frameJson: String) = Unit

        override fun onError(code: String, message: String) = Unit

        override fun onGlassesModel(modelName: String?) = Unit

        override fun onStage(stage: String, stereoMode: String?) {
            stages += stage to stereoMode
        }
    }

    @Test
    fun aStartWithoutAnActivityCarriesTheActivityStageInTheDetailMap() {
        val plugin = trackedPlugin(FakeBridge(model = "LumaUltra"))
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("start", null), result)

        assertEquals("unavailable", result.errorCode)
        val details = result.errorDetails as Map<*, *>
        assertEquals(
            com.onyxlens.wmr_tracking_dispatch.TrackingStartStage.ACTIVITY,
            details["stage"],
        )
    }
}
