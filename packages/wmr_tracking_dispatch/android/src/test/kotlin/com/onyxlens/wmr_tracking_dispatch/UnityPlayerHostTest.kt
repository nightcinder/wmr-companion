package com.onyxlens.wmr_tracking_dispatch

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class UnityPlayerHostTest {
    private class FakeViewHost(
        override val isLinked: Boolean = true,
        private val createResult: Boolean = true,
        private val throwOnCreate: Boolean = false,
    ) : UnityPlayerViewHost {
        var creates = 0
        var detaches = 0
        var pauses = 0
        var resumes = 0
        var destroys = 0
        var focusCalls = mutableListOf<Boolean>()
        var lastTarget: Any? = null
        var placements = mutableListOf<PlayerViewPlacement>()

        override fun create(target: Any, placement: PlayerViewPlacement): Boolean {
            creates += 1
            lastTarget = target
            placements += placement
            if (throwOnCreate) throw IllegalStateException("unity player failed")
            return createResult
        }

        override fun detach() {
            detaches += 1
        }

        override fun pause() {
            pauses += 1
        }

        override fun resume() {
            resumes += 1
        }

        override fun destroy() {
            destroys += 1
        }

        override fun configurationChanged(configuration: android.content.res.Configuration) = Unit

        override fun windowFocusChanged(focused: Boolean) {
            focusCalls += focused
        }
    }

    @Test
    fun hostsThePlayerOncePerActivity() {
        val facade = FakeViewHost()
        val host = UnityPlayerHost(facade)
        val activity = Any()

        val first = host.hostTarget(activity)
        val second = host.hostTarget(activity)

        assertTrue(first.hosted)
        assertEquals(UnityPlayerHost.STAGE_PLAYER_HOSTED, first.stage)
        assertEquals(1, facade.creates)
        assertTrue(second.hosted)
        assertTrue(host.isHosted)
    }

    @Test
    fun hostsThePlayerBehindExistingContent() {
        val facade = FakeViewHost()
        val host = UnityPlayerHost(facade)
        val activity = Any()

        host.hostTarget(activity)

        assertEquals(
            listOf(PlayerViewPlacement.BEHIND_EXISTING_CONTENT),
            facade.placements,
        )
    }

    @Test
    fun firstHostResumesAndFocusesThePlayer() {
        val facade = FakeViewHost()
        val host = UnityPlayerHost(facade)

        host.hostTarget(Any())

        assertEquals(1, facade.resumes)
        assertEquals(listOf(true), facade.focusCalls)
    }

    @Test
    fun reattachingTheSameActivityKeepsTheInitialLifecycleCalls() {
        val facade = FakeViewHost()
        val host = UnityPlayerHost(facade)
        val activity = Any()

        host.hostTarget(activity)
        host.hostTarget(activity)

        assertEquals(1, facade.creates)
        assertEquals(1, facade.resumes)
        assertEquals(listOf(true), facade.focusCalls)
    }

    @Test
    fun aNewActivityReplacesTheAttachedView() {
        val facade = FakeViewHost()
        val host = UnityPlayerHost(facade)
        val first = Any()
        val second = Any()

        host.hostTarget(first)
        host.hostTarget(second)

        assertEquals(2, facade.creates)
        assertEquals(1, facade.detaches)
        assertEquals(2, facade.resumes)
        assertEquals(listOf(true, true), facade.focusCalls)
        assertEquals(second, facade.lastTarget)
        assertEquals(
            listOf(
                PlayerViewPlacement.BEHIND_EXISTING_CONTENT,
                PlayerViewPlacement.BEHIND_EXISTING_CONTENT,
            ),
            facade.placements,
        )
    }

    @Test
    fun releaseRemovesTheViewAndIsIdempotent() {
        val facade = FakeViewHost()
        val host = UnityPlayerHost(facade)
        host.hostTarget(Any())

        host.release()
        host.release()

        assertFalse(host.isHosted)
        assertEquals(1, facade.detaches)
    }

    @Test
    fun missingUnityPlayerIsTypedUnavailableNotThrown() {
        val facade = FakeViewHost(isLinked = false)
        val host = UnityPlayerHost(facade)

        val result = host.hostTarget(Any())

        assertFalse(result.hosted)
        assertEquals(UnityPlayerHost.STAGE_UNAVAILABLE, result.stage)
        assertTrue(result.detail!!.contains("not linked"))
        assertEquals(0, facade.creates)
    }

    @Test
    fun aPlayerThatProducesNoViewIsAHostFailure() {
        val facade = FakeViewHost(createResult = false)
        val host = UnityPlayerHost(facade)

        val result = host.hostTarget(Any())

        assertFalse(result.hosted)
        assertEquals(UnityPlayerHost.STAGE_HOST_FAILED, result.stage)
        assertFalse(host.isHosted)
    }

    @Test
    fun aCreationExceptionIsReportedAsAStageNotACrash() {
        val facade = FakeViewHost(throwOnCreate = true)
        val host = UnityPlayerHost(facade)

        val result = host.hostTarget(Any())

        assertFalse(result.hosted)
        assertEquals(UnityPlayerHost.STAGE_HOST_FAILED, result.stage)
        assertEquals("unity player failed", result.detail)
    }

    @Test
    fun lifecycleIsForwardedOnlyWhileHosted() {
        val facade = FakeViewHost()
        val host = UnityPlayerHost(facade)

        host.onPause()
        host.onResume()
        host.onWindowFocusChanged(true)
        assertEquals(0, facade.pauses)
        assertEquals(0, facade.resumes)
        assertTrue(facade.focusCalls.isEmpty())

        host.hostTarget(Any())
        host.onPause()
        host.onResume()
        host.onWindowFocusChanged(false)
        host.onWindowFocusChanged(true)

        assertEquals(1, facade.pauses)
        assertEquals(2, facade.resumes)
        assertEquals(listOf(true, false, true), facade.focusCalls)
        assertEquals(0, facade.destroys)
    }

    @Test
    fun destroyReleasesAndTearsDownThePlayer() {
        val facade = FakeViewHost()
        val host = UnityPlayerHost(facade)
        host.hostTarget(Any())

        host.onDestroy()

        assertFalse(host.isHosted)
        assertEquals(1, facade.detaches)
        assertEquals(1, facade.destroys)
    }

    @Test
    fun aNullActivityIsTypedUnavailable() {
        val host = UnityPlayerHost(FakeViewHost())

        val result = host.host(null)

        assertFalse(result.hosted)
        assertEquals(UnityPlayerHost.STAGE_UNAVAILABLE, result.stage)
        assertTrue(result.detail != null)
    }
}
