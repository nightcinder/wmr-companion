package com.onyxlens.wmr_tracking_dispatch

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SharedUnityRuntimeTest {
    private class Recorder : SharedUnityRuntime.Handler {
        val frames = mutableListOf<String>()
        val errors = mutableListOf<Pair<String, String>>()
        val models = mutableListOf<String?>()

        override fun onFrame(frameJson: String) {
            frames += frameJson
        }

        override fun onError(code: String, message: String) {
            errors += code to message
        }

        override fun onGlassesModel(modelName: String?) {
            models += modelName
        }
    }

    @Test
    fun firstClaimCreatesThePlayerAndLaterVendorsReuseIt() {
        var creations = 0
        val runtime = SharedUnityRuntime {
            creations += 1
            true
        }

        val viture = runtime.claim(GlassesVendor.VITURE)
        val xreal = runtime.claim(GlassesVendor.XREAL)

        assertEquals(UnityClaimState.OWNER, viture.state)
        assertEquals(GlassesVendor.VITURE, viture.owner)
        assertEquals(UnityClaimState.REUSED, xreal.state)
        assertEquals(GlassesVendor.VITURE, xreal.owner)
        assertTrue(xreal.granted)
        assertEquals(1, creations)
        assertEquals(GlassesVendor.VITURE, runtime.ownerVendor)
    }

    @Test
    fun sameVendorClaimIsIdempotentAndDoesNotRecreate() {
        var creations = 0
        val runtime = SharedUnityRuntime {
            creations += 1
            true
        }

        assertEquals(UnityClaimState.OWNER, runtime.claim(GlassesVendor.VITURE).state)
        assertEquals(UnityClaimState.OWNER, runtime.claim(GlassesVendor.VITURE).state)
        assertEquals(1, creations)
    }

    @Test
    fun aFailedCreationIsRetriedOnTheNextClaim() {
        var creations = 0
        val runtime = SharedUnityRuntime {
            creations += 1
            false
        }

        val first = runtime.claim(GlassesVendor.VITURE)
        val second = runtime.claim(GlassesVendor.XREAL)

        assertEquals(UnityClaimState.UNAVAILABLE, first.state)
        assertEquals(UnityClaimState.UNAVAILABLE, second.state)
        assertEquals(false, first.granted)
        assertEquals(2, creations)
        assertNull(runtime.ownerVendor)
    }

    @Test
    fun noneNeverClaims() {
        val runtime = SharedUnityRuntime { true }
        val claim = runtime.claim(GlassesVendor.NONE)
        assertEquals(UnityClaimState.UNAVAILABLE, claim.state)
        assertNull(runtime.ownerVendor)
    }

    @Test
    fun callbacksRouteByVendorEvenWhenAnotherVendorOwnsThePlayer() {
        val runtime = SharedUnityRuntime { true }
        val viture = Recorder()
        val xreal = Recorder()
        runtime.register(GlassesVendor.VITURE, viture)
        runtime.register(GlassesVendor.XREAL, xreal)
        runtime.claim(GlassesVendor.VITURE)

        runtime.dispatchFrame(GlassesVendor.XREAL, "{\"v\":1}")
        runtime.dispatchFrame(GlassesVendor.VITURE, "{\"v\":2}")
        runtime.dispatchError(GlassesVendor.XREAL, "unavailable", "no xreal sdk")
        runtime.dispatchGlassesModel(GlassesVendor.XREAL, "Air2Ultra")

        assertEquals(listOf("{\"v\":1}"), xreal.frames)
        assertEquals(listOf("{\"v\":2}"), viture.frames)
        assertEquals(listOf("unavailable" to "no xreal sdk"), xreal.errors)
        assertEquals(listOf<String?>("Air2Ultra"), xreal.models)
        assertTrue(viture.errors.isEmpty())
        assertEquals("Air2Ultra", runtime.glassesModel(GlassesVendor.XREAL))
        assertNull(runtime.glassesModel(GlassesVendor.VITURE))
    }

    @Test
    fun aHostedSceneStaysHostedAfterTheStageIsClearedForANewSession() {
        val runtime = SharedUnityRuntime { true }
        runtime.claim(GlassesVendor.VITURE)

        assertEquals(false, runtime.hasHostedScene())
        runtime.dispatchStage(GlassesVendor.VITURE, "playerHosted", null)
        runtime.clearStage(GlassesVendor.VITURE)

        assertEquals(true, runtime.hasHostedScene())
        assertNull(runtime.stage(GlassesVendor.VITURE))

        runtime.clearHostedScene()

        assertEquals(false, runtime.hasHostedScene())
    }

    @Test
    fun untaggedCallbacksFallBackToTheOwner() {
        val runtime = SharedUnityRuntime { true }
        val owner = Recorder()
        runtime.register(GlassesVendor.VITURE, owner)
        runtime.claim(GlassesVendor.VITURE)

        runtime.dispatchFrame(GlassesVendor.NONE, "frame")

        assertEquals(listOf("frame"), owner.frames)
    }

    @Test
    fun unregisteredVendorCallbacksAreDropped() {
        val runtime = SharedUnityRuntime { true }
        val owner = Recorder()
        runtime.register(GlassesVendor.VITURE, owner)
        runtime.claim(GlassesVendor.VITURE)

        runtime.dispatchFrame(GlassesVendor.XREAL, "xreal frame")

        assertTrue(owner.frames.isEmpty())
    }

    @Test
    fun releaseDropsOwnershipButKeepsTheCreatedPlayer() {
        var creations = 0
        val runtime = SharedUnityRuntime {
            creations += 1
            true
        }
        runtime.claim(GlassesVendor.VITURE)
        runtime.release(GlassesVendor.VITURE)

        assertNull(runtime.ownerVendor)
        assertEquals(UnityClaimState.OWNER, runtime.claim(GlassesVendor.XREAL).state)
        assertEquals(1, creations)
    }

    @Test
    fun unregisterOnlyRemovesTheMatchingHandler() {
        val runtime = SharedUnityRuntime { true }
        val first = Recorder()
        val second = Recorder()
        runtime.register(GlassesVendor.VITURE, first)
        runtime.register(GlassesVendor.VITURE, second)
        runtime.unregister(GlassesVendor.VITURE, first)

        runtime.dispatchFrame(GlassesVendor.VITURE, "frame")

        assertTrue(first.frames.isEmpty())
        assertEquals(listOf("frame"), second.frames)
    }

    @Test
    fun aRuntimeWithNoPlayerFactoryFailsClosed() {
        val runtime = SharedUnityRuntime()

        val claim = runtime.claim(GlassesVendor.VITURE)

        assertEquals(UnityClaimState.UNAVAILABLE, claim.state)
        assertEquals(false, claim.granted)
        assertNull(runtime.ownerVendor)
    }

    @Test
    fun theFirstClaimCanSupplyTheRealPlayerCreationResult() {
        var hostCalls = 0
        val runtime = SharedUnityRuntime()
        val refused = runtime.claim(GlassesVendor.VITURE) {
            hostCalls += 1
            false
        }

        assertEquals(UnityClaimState.UNAVAILABLE, refused.state)
        assertEquals(1, hostCalls)

        // A failed attempt is not permanent: the next claim retries it.
        val retried = runtime.claim(GlassesVendor.VITURE) {
            hostCalls += 1
            true
        }
        assertEquals(UnityClaimState.OWNER, retried.state)
        assertEquals(2, hostCalls)
    }

    @Test
    fun stageReportsAreKeptPerVendorAndReachTheHandler() {
        val runtime = SharedUnityRuntime { true }
        val handler = RecordingHandler()
        runtime.register(GlassesVendor.VITURE, handler)

        runtime.dispatchStage(GlassesVendor.VITURE, "loaderStarted", "singlePassInstanced")

        assertEquals("loaderStarted", runtime.stage(GlassesVendor.VITURE)?.stage)
        assertEquals(
            "singlePassInstanced",
            runtime.stage(GlassesVendor.VITURE)?.stereoMode,
        )
        assertEquals(
            listOf<Pair<String, String?>>("loaderStarted" to "singlePassInstanced"),
            handler.stages,
        )
        assertNull(runtime.stage(GlassesVendor.XREAL))
    }

    @Test
    fun hostStageReportsRouteToTheVendorThatOwnsTheRuntime() {
        val runtime = SharedUnityRuntime { true }
        val viture = RecordingHandler()
        val xreal = RecordingHandler()
        runtime.register(GlassesVendor.VITURE, viture)
        runtime.register(GlassesVendor.XREAL, xreal)
        runtime.claim(GlassesVendor.XREAL)

        runtime.dispatchHostStage("playerHosted", "singlePassInstanced")

        assertEquals(
            listOf<Pair<String, String?>>("playerHosted" to "singlePassInstanced"),
            xreal.stages,
        )
        assertTrue(viture.stages.isEmpty())
        assertEquals("playerHosted", runtime.stage(GlassesVendor.XREAL)?.stage)
        assertNull(runtime.stage(GlassesVendor.VITURE))
    }

    @Test
    fun hostStageReportsBeforeAClaimStayWithViture() {
        val runtime = SharedUnityRuntime { true }
        val viture = RecordingHandler()
        runtime.register(GlassesVendor.VITURE, viture)

        runtime.dispatchHostStage("playerHosted", "unknown")

        assertEquals(listOf<Pair<String, String?>>("playerHosted" to "unknown"), viture.stages)
    }

    @Test
    fun clearStageDropsThePreviousSessionReport() {
        val runtime = SharedUnityRuntime { true }
        runtime.dispatchStage(GlassesVendor.VITURE, "firstFrame", "singlePassInstanced")

        runtime.clearStage(GlassesVendor.VITURE)

        assertNull(runtime.stage(GlassesVendor.VITURE))
    }

    @Test
    fun blankStageReportsAreIgnored() {
        val runtime = SharedUnityRuntime { true }

        runtime.dispatchStage(GlassesVendor.VITURE, "   ", "singlePass")

        assertNull(runtime.stage(GlassesVendor.VITURE))
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
}
