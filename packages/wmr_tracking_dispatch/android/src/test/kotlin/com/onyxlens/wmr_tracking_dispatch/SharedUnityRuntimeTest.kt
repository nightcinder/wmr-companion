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
    fun missingUnityRuntimeIsUnavailableAndIsNotRetried() {
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
        assertEquals(1, creations)
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
}
