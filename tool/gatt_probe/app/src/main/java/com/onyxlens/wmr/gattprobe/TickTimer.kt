package com.onyxlens.wmr.gattprobe

import kotlin.math.abs

enum class TickStepKind {
    BASELINE,
    STEP,
    DISCONTINUITY
}

data class TickStep(
    val kind: TickStepKind,
    val dtTicks: Long = 0L,
    val dtSeconds: Double = 0.0
)

class TickTimer(
    val window: Int = 256,
    val warmup: Int = 16,
    val refresh: Int = 32,
    val maxDeltaTicks: Long = 50_000_000L, // 5 seconds at 100 ns
    val discontinuityToleranceNs: Long = 100_000_000L // 100 ms
) {
    private var _prevTicks: Long? = null
    private var _prevRxUs: Long? = null
    private val _recent = ArrayList<Long>() // last deltas in arrival order, in ticks
    private var _sinceRefresh = 0
    private var _period: Long? = null
    private val _dts = ArrayList<Double>()
    private var _maxDt = 0.0
    private var _missing = 0
    private var _steps = 0
    private var _discontinuities = 0
    private var _longGaps = 0
    private var _elapsedTicks = 0L
    private var _rxElapsedUs = 0L

    val missing: Int get() = _missing
    val steps: Int get() = _steps
    val discontinuities: Int get() = _discontinuities
    val longGaps: Int get() = _longGaps
    val periodTicks: Long? get() = _period

    fun rebaseline() {
        _prevTicks = null
        _prevRxUs = null
    }

    fun advance(deviceTicks: Long, rxTimeUs: Long): TickStep {
        val prevTicks = _prevTicks
        val prevRx = _prevRxUs
        _prevTicks = deviceTicks
        _prevRxUs = rxTimeUs

        if (prevTicks == null || prevRx == null) {
            return TickStep(TickStepKind.BASELINE)
        }

        val dtTicks = Protocol.tickDelta(prevTicks, deviceTicks)
        val tickNs = dtTicks * 100L // 100 ns per tick
        val rxNs = (rxTimeUs - prevRx) * 1000L

        if (rxNs < 0 || abs(tickNs - rxNs) > discontinuityToleranceNs) {
            _discontinuities++
            _recent.clear()
            _sinceRefresh = 0
            _period = null
            return TickStep(TickStepKind.DISCONTINUITY)
        }

        val dt = dtTicks * 1e-7
        _steps++
        _elapsedTicks += dtTicks
        _rxElapsedUs += (rxTimeUs - prevRx)
        _dts.add(dt)
        if (_dts.size > window) {
            _dts.removeAt(0)
        }
        if (dt > _maxDt) {
            _maxDt = dt
        }
        if (dtTicks > maxDeltaTicks) {
            _longGaps++
        } else if (dtTicks > 0) {
            _count(dtTicks)
        }
        return TickStep(TickStepKind.STEP, dtTicks = dtTicks, dtSeconds = dt)
    }

    private fun _count(dtTicks: Long) {
        _recent.add(dtTicks)
        if (_recent.size > window) {
            _recent.removeAt(0)
        }
        _sinceRefresh++

        val currentPeriod = _period
        if (currentPeriod == null) {
            if (_recent.size >= warmup) {
                val p = _estimatePeriod()
                _sinceRefresh = 0
                if (p > 0) {
                    _period = p
                    // Deltas collected during warm-up are counted retroactively.
                    for (d in _recent) {
                        _missing += _lost(d, p)
                    }
                }
            }
            return
        }

        _missing += _lost(dtTicks, currentPeriod)
        if (_sinceRefresh >= refresh) {
            val p = _estimatePeriod()
            if (p > 0) {
                _period = p
            }
            _sinceRefresh = 0
        }
    }

    private fun _estimatePeriod(): Long {
        val sorted = _recent.sorted()
        val ref = sorted[sorted.size / 10]
        if (ref == 0L) return 0L
        val limit = ref + ref / 2L
        var m = 0
        while (m < sorted.size && sorted[m] <= limit) {
            m++
        }
        if (m == 0) return 0L
        return if (m % 2 != 0) {
            sorted[m / 2]
        } else {
            (sorted[m / 2 - 1] + sorted[m / 2]) / 2L
        }
    }

    companion object {
        private fun _lost(dtTicks: Long, period: Long): Int {
            val k = (dtTicks + period / 2L) / period
            return if (k > 1L) (k - 1L).toInt() else 0
        }
    }
}
