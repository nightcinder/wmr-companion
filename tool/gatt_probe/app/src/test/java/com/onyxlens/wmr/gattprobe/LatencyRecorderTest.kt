package com.onyxlens.wmr.gattprobe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LatencyRecorderTest {

    @Test
    fun testPercentiles() {
        val empty = UsPercentiles.of(emptyList())
        assertEquals(0, empty.count)
        assertEquals(0L, empty.p50)

        // 1 to 100
        val values = (1L..100L).toList()
        val p = UsPercentiles.of(values)
        assertEquals(100, p.count)
        assertEquals(1L, p.min)
        assertEquals(51L, p.p50)
        assertEquals(90L, p.p90)
        assertEquals(95L, p.p95)
        assertEquals(99L, p.p99)
        assertEquals(100L, p.max)
    }

    @Test
    fun testLatencyRecorderEchoAndReport() {
        val recorder = LatencyRecorder(
            started = "2026-10-23T04:30:00Z",
            originUs = 1000000L,
            stream = "batched"
        )
        recorder.useEcho()

        val sample = EchoSample(
            t1Us = 1100000L,
            t1DoneUs = 1105000L,
            t4Us = 1140000L,
            answer = Protocol.EchoAnswer(
                pingId = 1,
                rxTimeUs = 5000000L,
                turnaroundUs = 500L,
                queueDepth = 2
            )
        )
        recorder.addEcho(sample)

        assertEquals(40000L, sample.endToEndUs)
        assertEquals(39500L, sample.rttUs)

        // Add decoded record for LEFT hand (hand = 0)
        recorder.addRecord(
            hand = 0,
            sequence = 1L,
            arrivalUs = 1100000L,
            deviceTicks = 10000L,
            espRxUs = 5000000L
        )
        recorder.addRecord(
            hand = 0,
            sequence = 2L,
            arrivalUs = 1105000L,
            deviceTicks = 60000L,
            espRxUs = 5005000L
        )

        val report = recorder.report(
            nowUs = 120000000L,
            link = LatencyLink(mtu = 517, priorityRequested = true),
            echoIntervalUs = 250000L
        )

        val json = JsonWriter.toJsonString(report)
        assertTrue(json.contains("\"format\": \"wmr-latency\""))
        assertTrue(json.contains("\"version\": 2"))
        assertTrue(json.contains("\"stream\": \"batched\""))
        assertTrue(json.contains("\"measured\": true"))
        assertTrue(json.contains("\"sent\": 1"))
        assertTrue(json.contains("\"answered\": 1"))
        assertTrue(json.contains("\"ping_interval_us\": 250000"))
        assertTrue(json.contains("\"hand\": \"LEFT\""))
        assertTrue(json.contains("\"hand\": \"RIGHT\""))

        val echoCsv = recorder.toEchoCsv()
        assertTrue(echoCsv.startsWith(EchoRow.CSV_HEADER))
        assertTrue(echoCsv.contains("1,100000,105000,140000,40000,5000000,500,39500,2"))
    }

    @Test
    fun testNoStreamReport() {
        val recorder = LatencyRecorder(
            started = "2026-10-23T04:30:00Z",
            originUs = 1000000L,
            stream = "none"
        )
        recorder.useEcho()
        val report = recorder.report(nowUs = 2000000L)
        val json = JsonWriter.toJsonString(report)
        assertTrue(json.contains("\"stream\": \"none\""))
        assertTrue(json.contains("\"records\": 0"))
        assertTrue(json.contains("\"missing_from_ticks\": null"))
    }
}
