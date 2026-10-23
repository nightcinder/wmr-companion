package com.onyxlens.wmr.gattprobe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TickTimerTest {

    @Test
    fun testBaselineAndStep() {
        val timer = TickTimer()
        val s1 = timer.advance(deviceTicks = 1000L, rxTimeUs = 50000L)
        assertEquals(TickStepKind.BASELINE, s1.kind)

        // 1 tick = 100 ns = 0.1 us. 50000 ticks = 5 ms = 5000 us.
        val s2 = timer.advance(deviceTicks = 51000L, rxTimeUs = 55000L)
        assertEquals(TickStepKind.STEP, s2.kind)
        assertEquals(50000L, s2.dtTicks)
        assertEquals(0.005, s2.dtSeconds, 1e-6)
    }

    @Test
    fun testPeriodEstimationAndMissing() {
        val timer = TickTimer(warmup = 16)
        timer.advance(deviceTicks = 0L, rxTimeUs = 0L)

        // Feed 20 regular steps of 50000 ticks (5 ms)
        var ticks = 0L
        var rxUs = 0L
        for (i in 1..20) {
            ticks += 50000L
            rxUs += 5000L
            timer.advance(ticks, rxUs)
        }

        assertEquals(50000L, timer.periodTicks)
        assertEquals(0, timer.missing)

        // Now inject a gap of 2 missed reports (dt = 3 * period = 150000 ticks)
        ticks += 150000L
        rxUs += 15000L
        timer.advance(ticks, rxUs)

        assertEquals(2, timer.missing)
    }

    @Test
    fun testDiscontinuity() {
        val timer = TickTimer()
        timer.advance(deviceTicks = 1000L, rxTimeUs = 10000L)

        // Discontinuity: rxTime goes backwards or ticks jump excessively
        val step = timer.advance(deviceTicks = 1000L, rxTimeUs = 5000L)
        assertEquals(TickStepKind.DISCONTINUITY, step.kind)
        assertEquals(1, timer.discontinuities)
    }
}
