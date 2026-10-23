package com.onyxlens.wmr.gattprobe

import java.util.Locale
import kotlin.math.abs

data class UsPercentiles(
    val count: Int = 0,
    val min: Long = 0,
    val p50: Long = 0,
    val p90: Long = 0,
    val p95: Long = 0,
    val p99: Long = 0,
    val max: Long = 0
) {
    companion object {
        fun of(values: List<Long>): UsPercentiles {
            if (values.isEmpty()) return UsPercentiles()
            val sorted = values.sorted()
            fun at(q: Double): Long {
                val idx = Math.round(q * (sorted.size - 1)).toInt()
                return sorted[idx]
            }
            return UsPercentiles(
                count = sorted.size,
                min = sorted.first(),
                p50 = at(0.5),
                p90 = at(0.9),
                p95 = at(0.95),
                p99 = at(0.99),
                max = sorted.last()
            )
        }
    }
}

data class LatencyLink(
    val mtu: Int? = null,
    val rssiStart: Int? = null,
    val rssiEnd: Int? = null,
    val connectionIntervalUs: Int? = null,
    val phy: String? = null,
    val highPriorityRequested: Boolean? = null
)

data class EchoSample(
    val t1Us: Long,
    val t1DoneUs: Long,
    val t4Us: Long,
    val answer: Protocol.EchoAnswer
) {
    val endToEndUs: Long get() = t4Us - t1Us
    val rttUs: Long get() = endToEndUs - answer.turnaroundUs
    val offsetUs: Long
        get() = ((answer.rxTimeUs - t1Us) + (answer.rxTimeUs + answer.turnaroundUs - t4Us)) / 2L
}

data class EchoRow(
    val sample: EchoSample,
    val originUs: Long
) {
    fun toCsv(): String {
        val s = sample
        return "${s.answer.pingId},${s.t1Us - originUs},${s.t1DoneUs - originUs},${s.t4Us - originUs}," +
                "${s.endToEndUs},${s.answer.rxTimeUs},${s.answer.turnaroundUs},${s.rttUs}," +
                "${s.answer.queueDepth},${s.offsetUs}"
    }

    companion object {
        const val CSV_HEADER =
            "ping_id,t1_us,t1_done_us,t4_us,end_to_end_us,esp_rx_us,turnaround_us,rtt_us,queue_depth,clock_offset_us"
    }
}

data class LatencyRow(
    val hand: Int,
    val sequence: Long,
    val arrivalUs: Long,
    val interArrivalUs: Long?,
    val sequenceDelta: Int?,
    val deviceTicks: Long?,
    val deviceDtUs: Long?,
    val espRxUs: Long?
) {
    fun toCsv(): String {
        val handStr = when (hand) {
            Protocol.WMR_HAND_LEFT -> "LEFT"
            Protocol.WMR_HAND_RIGHT -> "RIGHT"
            else -> "HAND$hand"
        }
        return "$handStr,$sequence,$arrivalUs," +
                "${interArrivalUs ?: ""}," +
                "${sequenceDelta ?: ""}," +
                "${deviceTicks ?: ""}," +
                "${deviceDtUs ?: ""}," +
                "${espRxUs ?: ""}"
    }

    companion object {
        const val CSV_HEADER =
            "hand,sequence,arrival_us,inter_arrival_us,seq_delta,device_ticks,device_dt_us,esp_rx_us"
    }
}

data class LatencyHandSummary(
    val hand: Int,
    val records: Int,
    val arrivals: Int,
    val spanUs: Long,
    val ratePerSecond: Double,
    val interArrival: UsPercentiles,
    val stalls: Int,
    val sequenceGaps: Int,
    val sequenceLoss: Double,
    val outOfOrder: Int,
    val missingFromTicks: Int?,
    val tickLoss: Double?,
    val periodUs: Int?,
    val delay: UsPercentiles?,
    val delayVariation: UsPercentiles?
)

data class EchoSummary(
    val sent: Int,
    val answered: Int,
    val timeouts: Int,
    val failedWrites: Int,
    val rtt: UsPercentiles,
    val endToEnd: UsPercentiles,
    val turnaround: UsPercentiles,
    val maxQueueDepth: Int,
    val counters: Map<String, Int>,
    val pingIntervalUs: Long? = null
)

data class LatencyReport(
    val started: String,
    val stream: String,
    val durationUs: Long,
    val hands: List<LatencyHandSummary>,
    val link: LatencyLink,
    val echo: EchoSummary?,
    val counters: Map<String, Int> = mapOf(
        "incomplete_frames" to 0,
        "reassembly_errors" to 0,
        "decoded_parse_errors" to 0
    ),
    val rowsDropped: Int = 0,
    val modeChanged: Boolean = false
)

private class HandState {
    var records: Int = 0
    var arrivals: Int = 0
    var firstUs: Long? = null
    var lastUs: Long? = null
    var lastSeq: Long? = null
    var gaps: Int = 0
    var outOfOrder: Int = 0
    var stalls: Int = 0
    val interArrival = ArrayList<Long>()

    var timer: TickTimer? = null
    var lastOffset: Long? = null
    val variation = ArrayList<Long>()

    var windowStartUs: Long? = null
    val windowOffsets = ArrayList<Long>()
    val delay = ArrayList<Long>()

    fun closeWindow() {
        if (windowOffsets.isEmpty()) return
        val min = windowOffsets.minOrNull() ?: return
        for (o in windowOffsets) {
            delay.add(o - min)
        }
        windowOffsets.clear()
    }
}

class LatencyRecorder(
    val started: String,
    val originUs: Long,
    val stream: String,
    val maxRows: Int = 250000
) {
    companion object {
        const val LATENCY_FORMAT_NAME = "wmr-latency"
        const val LATENCY_FORMAT_VERSION = 2
        const val LATENCY_STALL_US = 50000L
        const val LATENCY_DELAY_WINDOW_US = 10000000L // 10 seconds

        fun round(v: Double, digits: Int): Double {
            return String.format(Locale.US, "%.${digits}f", v).toDouble()
        }
    }

    private val _hands = arrayOf(HandState(), HandState())
    private val _rows = ArrayList<LatencyRow>()
    private val _echoRows = ArrayList<EchoRow>()
    private var _echoTimeouts = 0
    private var _echoFailed = 0
    private var _echoSkipped = 0
    private var _echoLateOrDup = 0
    private var _echoBadAnswers = 0
    private var _decodedParseErrors = 0
    private var _echoUsed = false
    private var _rowsDropped = 0
    private var _modeChanged = false

    val echoUsed: Boolean @Synchronized get() = _echoUsed
    val rowsDropped: Int @Synchronized get() = _rowsDropped
    val rows: List<LatencyRow> @Synchronized get() = ArrayList(_rows)
    val echoRows: List<EchoRow> @Synchronized get() = ArrayList(_echoRows)
    val echoTimeouts: Int @Synchronized get() = _echoTimeouts
    val echoFailed: Int @Synchronized get() = _echoFailed
    val echoSkipped: Int @Synchronized get() = _echoSkipped
    val decodedParseErrors: Int @Synchronized get() = _decodedParseErrors

    @Synchronized
    fun useEcho() {
        _echoUsed = true
    }

    @Synchronized
    fun addEcho(sample: EchoSample) {
        _echoUsed = true
        _echoRows.add(EchoRow(sample, originUs))
    }

    @Synchronized
    fun addEchoTimeout() {
        _echoUsed = true
        _echoTimeouts++
    }

    @Synchronized
    fun addEchoFailure() {
        _echoUsed = true
        _echoFailed++
    }

    @Synchronized
    fun addEchoSkipped() {
        _echoUsed = true
        _echoSkipped++
    }

    @Synchronized
    fun addEchoLateOrDuplicate() {
        _echoUsed = true
        _echoLateOrDup++
    }

    @Synchronized
    fun addEchoBadAnswer() {
        _echoUsed = true
        _echoBadAnswers++
    }

    @Synchronized
    fun addDecodedParseError() {
        _decodedParseErrors++
    }

    @Synchronized
    fun markModeChanged() {
        _modeChanged = true
    }

    @Synchronized
    fun addRecord(
        hand: Int,
        sequence: Long,
        arrivalUs: Long,
        deviceTicks: Long,
        espRxUs: Long
    ) {
        if (hand !in 0 until Protocol.WMR_NUM_CONTROLLERS) return
        val s = _hands[hand]
        s.records++

        var inter: Long? = null
        val last = s.lastUs
        if (last == null) {
            s.arrivals++
            s.firstUs = arrivalUs
        } else if (arrivalUs != last) {
            val delta = arrivalUs - last
            inter = delta
            s.arrivals++
            s.interArrival.add(delta)
            if (delta > LATENCY_STALL_US) {
                s.stalls++
            }
        } else {
            inter = 0L
        }
        s.lastUs = arrivalUs

        var seqDelta: Int? = null
        val lastSeq = s.lastSeq
        if (lastSeq != null) {
            val d = Protocol.sequenceDelta(lastSeq, sequence)
            seqDelta = d
            if (d > 1) {
                s.gaps += d - 1
            } else if (d <= 0) {
                s.outOfOrder++
            }
        }
        s.lastSeq = sequence

        var deviceDtUs: Long? = null
        val timer = s.timer ?: TickTimer().also { s.timer = it }
        val step = timer.advance(deviceTicks, espRxUs)
        if (step.kind == TickStepKind.STEP) {
            deviceDtUs = step.dtTicks / 10L
        }
        _addDelay(s, arrivalUs, espRxUs, step.kind)

        if (_rows.size < maxRows) {
            _rows.add(
                LatencyRow(
                    hand = hand,
                    sequence = sequence,
                    arrivalUs = arrivalUs - originUs,
                    interArrivalUs = inter,
                    sequenceDelta = seqDelta,
                    deviceTicks = deviceTicks,
                    deviceDtUs = deviceDtUs,
                    espRxUs = espRxUs
                )
            )
        } else {
            _rowsDropped++
        }
    }

    private fun _addDelay(s: HandState, arrivalUs: Long, espRxUs: Long, kind: TickStepKind) {
        val offset = arrivalUs - espRxUs
        if (kind == TickStepKind.DISCONTINUITY) {
            s.closeWindow()
            s.windowStartUs = null
            s.lastOffset = null
        }
        val prev = s.lastOffset
        if (prev != null) {
            s.variation.add(abs(offset - prev))
        }
        s.lastOffset = offset

        val start = s.windowStartUs
        if (start == null || arrivalUs - start >= LATENCY_DELAY_WINDOW_US) {
            s.closeWindow()
            s.windowStartUs = arrivalUs
        }
        s.windowOffsets.add(offset)
    }

    @Synchronized
    fun report(
        nowUs: Long,
        link: LatencyLink = LatencyLink(),
        echoIntervalUs: Long? = null
    ): LatencyReport {
        return LatencyReport(
            started = started,
            stream = stream,
            durationUs = nowUs - originUs,
            link = link,
            echo = if (_echoUsed) _echoSummary(echoIntervalUs) else null,
            counters = mapOf(
                "incomplete_frames" to 0,
                "reassembly_errors" to 0,
                "decoded_parse_errors" to _decodedParseErrors
            ),
            rowsDropped = _rowsDropped,
            modeChanged = _modeChanged,
            hands = listOf(
                _summary(Protocol.WMR_HAND_LEFT, _hands[0]),
                _summary(Protocol.WMR_HAND_RIGHT, _hands[1])
            )
        )
    }

    private fun _echoSummary(echoIntervalUs: Long?): EchoSummary {
        val samples = _echoRows.map { it.sample }
        var maxQueue = 0
        for (s in samples) {
            if (s.answer.queueDepth > maxQueue) {
                maxQueue = s.answer.queueDepth
            }
        }
        val counters = mapOf(
            "late_or_duplicate_answers" to _echoLateOrDup,
            "bad_answers" to _echoBadAnswers,
            "pings_skipped_busy" to _echoSkipped
        )
        return EchoSummary(
            sent = samples.size + _echoTimeouts + _echoFailed,
            answered = samples.size,
            timeouts = _echoTimeouts,
            failedWrites = _echoFailed,
            rtt = UsPercentiles.of(samples.map { it.rttUs }),
            endToEnd = UsPercentiles.of(samples.map { it.endToEndUs }),
            turnaround = UsPercentiles.of(samples.map { it.answer.turnaroundUs }),
            maxQueueDepth = maxQueue,
            counters = counters,
            pingIntervalUs = echoIntervalUs
        )
    }

    private fun _summary(hand: Int, s: HandState): LatencyHandSummary {
        val timer = s.timer
        val delayList: List<Long>?
        val delayVarList: List<Long>?
        val periodUs: Int?
        val missingFromTicks: Int?
        val tickLoss: Double?

        if (timer != null) {
            val open = s.windowOffsets
            val min = if (open.isEmpty()) 0L else open.minOrNull() ?: 0L
            val allDelay = ArrayList(s.delay)
            for (o in open) {
                allDelay.add(o - min)
            }
            delayList = allDelay
            delayVarList = s.variation
            val pTicks = timer.periodTicks
            periodUs = pTicks?.let { (it / 10L).toInt() }
            val m = timer.missing
            missingFromTicks = m
            val total = s.records + m
            tickLoss = if (total == 0) 0.0 else round(m.toDouble() / total.toDouble(), 4)
        } else {
            delayList = null
            delayVarList = null
            periodUs = null
            missingFromTicks = null
            tickLoss = null
        }

        val spanUs = (s.lastUs ?: 0L) - (s.firstUs ?: 0L)
        val ratePerSecond = if (spanUs <= 0) 0.0 else round((s.records * 1e6) / spanUs.toDouble(), 2)
        val totalSeq = s.records + s.gaps
        val seqLoss = if (totalSeq == 0) 0.0 else round(s.gaps.toDouble() / totalSeq.toDouble(), 4)

        return LatencyHandSummary(
            hand = hand,
            records = s.records,
            arrivals = s.arrivals,
            spanUs = spanUs,
            ratePerSecond = ratePerSecond,
            interArrival = UsPercentiles.of(s.interArrival),
            stalls = s.stalls,
            sequenceGaps = s.gaps,
            sequenceLoss = seqLoss,
            outOfOrder = s.outOfOrder,
            missingFromTicks = missingFromTicks,
            tickLoss = tickLoss,
            periodUs = periodUs,
            delay = delayList?.let { UsPercentiles.of(it) },
            delayVariation = delayVarList?.let { UsPercentiles.of(it) }
        )
    }

    @Synchronized
    fun toEchoCsv(): String {
        val sb = StringBuilder()
        sb.append(EchoRow.CSV_HEADER).append("\n")
        for (r in _echoRows) {
            sb.append(r.toCsv()).append("\n")
        }
        return sb.toString()
    }

    @Synchronized
    fun toSamplesCsv(): String {
        val sb = StringBuilder()
        sb.append(LatencyRow.CSV_HEADER).append("\n")
        for (r in _rows) {
            sb.append(r.toCsv()).append("\n")
        }
        return sb.toString()
    }
}
