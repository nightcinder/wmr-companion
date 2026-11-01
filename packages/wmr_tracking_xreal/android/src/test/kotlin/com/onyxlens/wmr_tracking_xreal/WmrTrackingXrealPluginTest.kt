package com.onyxlens.wmr_tracking_xreal

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

import com.onyxlens.wmr_tracking_dispatch.GlassesVendor
import com.onyxlens.wmr_tracking_dispatch.PlayerHost
import com.onyxlens.wmr_tracking_dispatch.PlayerHostResult
import com.onyxlens.wmr_tracking_dispatch.SharedUnityRuntime
import com.onyxlens.wmr_tracking_dispatch.TrackingStartStage
import com.onyxlens.wmr_tracking_dispatch.UnityPlayerHost
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class WmrTrackingXrealPluginTest {
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

    private class ThrowingBridge(
        private val throwOnModel: Boolean = true,
        private val throwOnSend: Boolean = false,
    ) : XrealUnityBridge {
        override val isUnityAvailable: Boolean = true

        override fun queryGlassesModel(): String? {
            if (throwOnModel) throw IllegalStateException("model query failed")
            return "Air2Ultra"
        }

        override fun sendCommand(payloadJson: String, gameObject: String, method: String): Boolean {
            if (throwOnSend) throw IllegalStateException("host command failed")
            return true
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

    private class RecordingSink : EventChannel.EventSink {
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

    private fun xrealPlugin(
        bridge: XrealUnityBridge,
        runtime: SharedUnityRuntime = SharedUnityRuntime { true },
        host: PlayerHost = FakePlayerHost(),
    ) = WmrTrackingXrealPlugin(bridge, runtime, host)

    @Test
    fun capabilitiesDefersAnUnreportedGlassesModelToTheStartHandshake() {
        val bridge = FakeBridge(isUnityAvailable = true, model = null)
        val plugin = xrealPlugin(bridge)

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
        val plugin = xrealPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(false, caps["modelReported"])
        assertEquals(true, caps["supported"])
        assertEquals(26, caps["handJointCount"])
        assertNull(caps["reason"])
    }

    @Test
    fun capabilitiesReportsHeadOnlyForOneSeries() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "One")
        val plugin = xrealPlugin(bridge)

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
        val plugin = xrealPlugin(bridge)

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
    fun capabilitiesFailsClosedForAReportedModelItCannotClassify() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air3")
        val plugin = xrealPlugin(bridge)

        val caps = plugin.capabilities()
        assertEquals(true, caps["modelReported"])
        assertEquals(false, caps["supported"])
        assertEquals(false, caps["handTracking"])
        assertEquals("Air3", caps["glassesModel"])
        assertEquals(
            "XREAL hand tracking requires Air 2 Ultra (found Air3)",
            caps["reason"],
        )
    }

    @Test
    fun capabilitiesReportsSupportedOnlyForAir2Ultra() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air2Ultra")
        val plugin = xrealPlugin(bridge)

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
        val plugin = xrealPlugin(bridge, host = FakePlayerHost(isHosted = false))

        val caps = plugin.capabilities()
        assertEquals(false, caps["unityAvailable"])
        assertEquals(false, caps["supported"])
        assertEquals(0, caps["handJointCount"])
        assertEquals("Unknown", caps["glassesModel"])
        assertTrue((caps["reason"] as String).contains("not linked"))
        assertEquals(false, caps["playerHosted"])
        assertEquals("notHosted", caps["stage"])
        assertEquals("unknown", caps["stereoMode"])
    }

    @Test
    fun startUnityRelayDefersAnUnreportedGlassesModelToUnity() {
        val bridge = FakeBridge(isUnityAvailable = true, model = null)
        val plugin = xrealPlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertTrue(reply.errors.isEmpty())
        assertEquals(1, reply.reports.size)
        assertEquals(0, bridge.sentCommands.size)
        assertTrue(plugin.flushPendingStart())
        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"start\""))
    }

    @Test
    fun startUnityRelayFailsForOneSeries() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "One")
        val plugin = xrealPlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals("unsupported", reply.errors[0].first)
        assertEquals(
            "XREAL hand tracking requires Air 2 Ultra (found One)",
            reply.errors[0].second,
        )
        assertEquals(TrackingStartStage.MODEL, reply.errors[0].third)
        assertTrue(bridge.sentCommands.isEmpty())
    }

    @Test
    fun startUnityRelayRejectsAReportedModelItCannotClassify() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air3")
        val plugin = xrealPlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals("unsupported", reply.errors[0].first)
        assertEquals(
            "XREAL hand tracking requires Air 2 Ultra (found Air3)",
            reply.errors[0].second,
        )
        assertTrue(bridge.sentCommands.isEmpty())
    }

    @Test
    fun deliverUnityErrorSendsStopAndReportsTheRuntimeStage() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air2Ultra")
        val plugin = xrealPlugin(bridge)
        val sink = RecordingSink()
        plugin.onListen(null, sink)
        plugin.startUnityRelay(RecordingReply())
        bridge.sentCommands.clear()

        plugin.deliverUnityError("protocol", "malformed relay frame")

        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"stop\""))
        assertEquals("protocol", sink.errors.single().first)
        val details = sink.errors.single().third as Map<*, *>
        assertEquals(TrackingStartStage.RUNTIME, details["stage"])
    }

    @Test
    fun startUnityRelaySucceedsForAir2Ultra() {
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air2Ultra")
        val plugin = xrealPlugin(bridge)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertTrue(reply.errors.isEmpty())
        assertEquals(1, reply.reports.size)
        // A cold player is still initialising: no UnitySendMessage yet.
        assertTrue(bridge.sentCommands.isEmpty())

        plugin.deliverUnityStage(UnityPlayerHost.STAGE_PLAYER_HOSTED, null)

        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"start\""))
    }

    @Test
    fun startReusesThePlayerOwnedByViture() {
        var creations = 0
        val runtime = SharedUnityRuntime {
            creations += 1
            true
        }
        runtime.claim(GlassesVendor.VITURE)
        val bridge = FakeBridge(isUnityAvailable = true, model = "Air2Ultra")
        val plugin = xrealPlugin(bridge, runtime)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertTrue(reply.errors.isEmpty())
        assertEquals(1, reply.reports.size)
        assertEquals(GlassesVendor.VITURE, runtime.ownerVendor)
        assertEquals(1, creations)
    }

    @Test
    fun xrealFirstHostsThePlayerBeforeClaimingTheRuntime() {
        // A factory that refuses proves the claim is granted by the attach
        // result, not by the linked class or the previous factory default.
        val runtime = SharedUnityRuntime { false }
        val host = FakePlayerHost()
        val plugin = xrealPlugin(FakeBridge(model = "Air2Ultra"), runtime, host)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertTrue(reply.errors.isEmpty())
        assertEquals(1, host.hostCalls)
        assertEquals(GlassesVendor.XREAL, runtime.ownerVendor)
        assertEquals(true, reply.reports.single()["playerHosted"])
        assertEquals(UnityPlayerHost.STAGE_PLAYER_HOSTED, reply.reports.single()["stage"])
    }

    @Test
    fun startFailsWithTheHostStageWhenNoPlayerCanBeHosted() {
        val runtime = SharedUnityRuntime { false }
        val host = FakePlayerHost(
            isHosted = false,
            detail = "com.unity3d.player.UnityPlayer is not linked into this build",
        )
        val bridge = FakeBridge(model = "Air2Ultra")
        val plugin = xrealPlugin(bridge, runtime, host)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals("unavailable", reply.errors.single().first)
        assertEquals(UnityPlayerHost.STAGE_UNAVAILABLE, reply.errors.single().third)
        assertTrue(reply.errors.single().second.contains("not linked"))
        assertTrue(bridge.sentCommands.isEmpty())
        assertNull(runtime.ownerVendor)
    }

    @Test
    fun aThrowingHostFailsTheStartWithoutClaimingTheRuntime() {
        val runtime = SharedUnityRuntime { true }
        val host = FakePlayerHost(throwOnHost = true)
        val plugin = xrealPlugin(FakeBridge(model = "Air2Ultra"), runtime, host)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals(TrackingStartStage.START_FAILED, reply.errors.single().third)
        assertNull(runtime.ownerVendor)
        assertEquals(1, host.releases)
    }

    @Test
    fun aThrowingBridgeFailsTheStartExactlyOnceAndReleasesThePlayer() {
        val runtime = SharedUnityRuntime { true }
        val host = FakePlayerHost()
        val plugin = xrealPlugin(ThrowingBridge(), runtime, host)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals(TrackingStartStage.START_FAILED, reply.errors.single().third)
        assertNull(runtime.ownerVendor)
        assertEquals(1, host.releases)
    }

    @Test
    fun aThrowingStartCommandFailsTheStartAndReleasesTheClaim() {
        val runtime = SharedUnityRuntime { true }
        runtime.dispatchStage(GlassesVendor.XREAL, UnityPlayerHost.STAGE_PLAYER_HOSTED, null)
        val host = FakePlayerHost()
        val plugin = xrealPlugin(
            ThrowingBridge(throwOnModel = false, throwOnSend = true),
            runtime,
            host,
        )
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals(TrackingStartStage.START_FAILED, reply.errors.single().third)
        assertNull(runtime.ownerVendor)
        assertEquals(1, host.releases)
    }

    @Test
    fun unsupportedModelReleasesTheClaim() {
        val runtime = SharedUnityRuntime { true }
        val plugin = xrealPlugin(FakeBridge(model = "One"), runtime)
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertNull(runtime.ownerVendor)
    }

    @Test
    fun failedStartCommandReleasesTheClaim() {
        val runtime = SharedUnityRuntime { true }
        runtime.dispatchStage(GlassesVendor.XREAL, UnityPlayerHost.STAGE_PLAYER_HOSTED, null)
        val plugin = xrealPlugin(
            FakeBridge(model = "Air2Ultra", sendSucceeds = false),
            runtime,
        )
        val reply = RecordingReply()

        plugin.startUnityRelay(reply)

        assertEquals(1, reply.errors.size)
        assertEquals(TrackingStartStage.COMMAND, reply.errors.single().third)
        assertNull(runtime.ownerVendor)
    }

    @Test
    fun stopAndUnityErrorReleaseTheClaim() {
        val runtime = SharedUnityRuntime { true }
        val plugin = xrealPlugin(FakeBridge(model = "Air2Ultra"), runtime)
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

    @Test
    fun aNewStartClearsThePreviousSessionsStage() {
        val runtime = SharedUnityRuntime { true }
        val plugin = xrealPlugin(FakeBridge(model = "Air2Ultra"), runtime)
        plugin.startUnityRelay(RecordingReply())
        runtime.dispatchStage(GlassesVendor.XREAL, "firstFrame", "singlePassInstanced")

        plugin.startUnityRelay(RecordingReply())

        assertEquals("playerHosted", plugin.capabilities()["stage"])
        assertEquals("unknown", plugin.capabilities()["stereoMode"])
    }

    @Test
    fun capabilitiesReportHostingAndTheLastStage() {
        val runtime = SharedUnityRuntime { true }
        val host = FakePlayerHost()
        val plugin = xrealPlugin(FakeBridge(model = "Air2Ultra"), runtime, host)
        plugin.startUnityRelay(RecordingReply())
        runtime.dispatchStage(GlassesVendor.XREAL, "firstFrame", "singlePassInstanced")

        val caps = plugin.capabilities()

        assertEquals(true, caps["playerHosted"])
        assertEquals("singlePassInstanced", caps["stereoMode"])
        assertEquals("firstFrame", caps["stage"])
    }

    @Test
    fun theStartCommandIsReplayedWhenTheSceneBecomesReady() {
        val bridge = FakeBridge(model = "Air2Ultra")
        val plugin = xrealPlugin(bridge)
        plugin.startUnityRelay(RecordingReply())
        assertEquals(0, bridge.sentCommands.size)

        assertTrue(plugin.flushPendingStart())

        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"start\""))

        plugin.flushPendingStart()
        assertEquals(1, bridge.sentCommands.size)
    }

    @Test
    fun aHostedSceneReportReplaysThePendingStart() {
        val bridge = FakeBridge(model = "Air2Ultra")
        val plugin = xrealPlugin(bridge)
        plugin.startUnityRelay(RecordingReply())
        assertEquals(0, bridge.sentCommands.size)

        plugin.deliverUnityStage(UnityPlayerHost.STAGE_PLAYER_HOSTED, "singlePassInstanced")

        assertEquals(1, bridge.sentCommands.size)
        assertTrue(bridge.sentCommands[0].contains("\"cmd\":\"start\""))
    }

    @Test
    fun aStoppedSourceDoesNotReplayTheStart() {
        val bridge = FakeBridge(model = "Air2Ultra")
        val plugin = xrealPlugin(bridge)
        plugin.startUnityRelay(RecordingReply())

        plugin.onMethodCall(MethodCall("stop", null), RecordingResult())
        val sentAfterStop = bridge.sentCommands.size
        plugin.flushPendingStart()

        assertEquals(sentAfterStop, bridge.sentCommands.size)
    }

    @Test
    fun aDeniedPermissionFailsTheHeldStartWithThePermissionStage() {
        val plugin = xrealPlugin(FakeBridge(model = "Air2Ultra"))
        val reply = RecordingReply()
        assertTrue(plugin.pendingStart.hold(reply))

        val handled = plugin.onRequestPermissionsResult(
            WmrTrackingXrealPlugin.PERMISSION_REQUEST_CODE,
            arrayOf(WmrTrackingXrealPlugin.PERMISSION_CAMERA),
            intArrayOf(android.content.pm.PackageManager.PERMISSION_DENIED),
        )

        assertTrue(handled)
        assertEquals("permissionDenied", reply.errors.single().first)
        assertEquals(TrackingStartStage.PERMISSION, reply.errors.single().third)
    }

    @Test
    fun stopWhilePermissionIsPendingFailsTheHeldStartWithThePendingStage() {
        val plugin = xrealPlugin(FakeBridge(model = "Air2Ultra"))
        val reply = RecordingReply()
        assertTrue(plugin.pendingStart.hold(reply))

        plugin.onMethodCall(MethodCall("stop", null), RecordingResult())

        assertEquals("unavailable", reply.errors.single().first)
        assertEquals(TrackingStartStage.PENDING, reply.errors.single().third)
    }

    @Test
    fun aStartWithoutAnActivityCarriesTheActivityStageInTheDetailMap() {
        val plugin = xrealPlugin(FakeBridge(model = "Air2Ultra"))
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("start", null), result)

        assertEquals("unavailable", result.errorCode)
        val details = result.errorDetails as Map<*, *>
        assertEquals(TrackingStartStage.ACTIVITY, details["stage"])
    }
}
