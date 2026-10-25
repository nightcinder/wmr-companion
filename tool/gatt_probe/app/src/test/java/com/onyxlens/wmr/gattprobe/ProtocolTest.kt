package com.onyxlens.wmr.gattprobe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ProtocolTest {

    @Test
    fun testEchoRequestEncoding() {
        val bytes = Protocol.encodeEchoRequest(0x1234)
        assertEquals(4, bytes.size)
        assertEquals(1, bytes[0].toInt())
        assertEquals(0, bytes[1].toInt())
        assertEquals(0x34, bytes[2].toInt() and 0xFF)
        assertEquals(0x12, bytes[3].toInt() and 0xFF)
    }

    @Test
    fun testEchoAnswerParsing() {
        val buffer = ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(1) // version
        buffer.put(0) // reserved
        buffer.putShort(42.toShort()) // pingId
        buffer.putLong(123456789L) // rxTimeUs
        buffer.putInt(500) // turnaroundUs
        buffer.putShort(3.toShort()) // queueDepth
        buffer.putShort(0.toShort()) // reserved

        val res = Protocol.parseEchoAnswer(buffer.array())
        assertTrue(res is Protocol.EchoParseResult.Ok)
        val answer = (res as Protocol.EchoParseResult.Ok).answer
        assertEquals(42, answer.pingId)
        assertEquals(123456789L, answer.rxTimeUs)
        assertEquals(500L, answer.turnaroundUs)
        assertEquals(3, answer.queueDepth)
    }

    @Test
    fun testDecodedBatchParsing() {
        // Header: version=2, count=1
        val buffer = ByteBuffer.allocate(2 + 56).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(2) // batch version
        buffer.put(1) // count = 1

        // Record:
        buffer.put(1) // record version = 1
        buffer.put(0) // hand = 0 (LEFT)
        buffer.put(0) // flags
        buffer.put(0) // buttons
        buffer.putInt(100) // sequence
        buffer.putLong(987654321L) // rxTimeUs
        buffer.putInt(50000) // deviceTicks
        // rest 36 bytes zeroes

        val res = Protocol.parseDecodedBatch(buffer.array())
        assertTrue(res.isOk)
        assertEquals(0, res.parseErrors)
        val records = res.records
        assertEquals(1, records.size)
        val r = records[0]
        assertEquals(Protocol.WMR_HAND_LEFT, r.hand)
        assertEquals(100L, r.sequence)
        assertEquals(987654321L, r.rxTimeUs)
        assertEquals(50000L, r.deviceTicks)
    }

    @Test
    fun testDecodedBatchWithCorruptedRecord() {
        // Header: version=2, count=2
        val buffer = ByteBuffer.allocate(2 + 56 * 2).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(2) // batch version
        buffer.put(2) // count = 2

        // Record 1: valid
        buffer.put(1) // version = 1
        buffer.put(0) // hand = 0 (LEFT)
        buffer.put(0)
        buffer.put(0)
        buffer.putInt(100)
        buffer.putLong(987654321L)
        buffer.putInt(50000)
        buffer.position(2 + 56)

        // Record 2: corrupted version (e.g. 99)
        buffer.put(99)
        buffer.put(1)
        buffer.position(2 + 56 * 2)

        val res = Protocol.parseDecodedBatch(buffer.array())
        assertEquals(1, res.records.size)
        assertEquals(1, res.parseErrors)
    }

    @Test
    fun testDeltas() {
        assertEquals(1, Protocol.sequenceDelta(10, 11))
        assertEquals(-1, Protocol.sequenceDelta(11, 10))
        assertEquals(1, Protocol.sequenceDelta(0xFFFFFFFFL, 0L))

        assertEquals(100L, Protocol.tickDelta(500L, 600L))
        assertEquals(1L, Protocol.tickDelta(0xFFFFFFFFL, 0L))
    }

    @Test
    fun testBridgeAdvertisementMatching() {
        assertTrue(Protocol.isWmrBridgeAdvertisement("WMR Bridge", emptyList()))
        assertTrue(Protocol.isWmrBridgeAdvertisement("WMR Bridge L", null))
        assertTrue(Protocol.isWmrBridgeAdvertisement("WMR Bridge R", null))
        assertTrue(Protocol.isWmrBridgeAdvertisement(null, listOf(Protocol.WMR_SERVICE_UUID)))
        assertEquals(false, Protocol.isWmrBridgeAdvertisement("Other Device", emptyList()))
        assertEquals(false, Protocol.isWmrBridgeAdvertisement(null, null))
    }
}
