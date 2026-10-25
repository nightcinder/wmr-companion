package com.onyxlens.wmr.gattprobe

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

object Protocol {
    val WMR_BRIDGE_NAME = "WMR Bridge"

    val WMR_SERVICE_UUID: UUID = UUID.fromString("0000ff10-0000-1000-8000-00805f9b34fb")

    fun isWmrBridgeAdvertisement(deviceName: String?, serviceUuids: List<UUID>?): Boolean {
        if (serviceUuids?.any { it == WMR_SERVICE_UUID } == true) {
            return true
        }
        return deviceName?.startsWith(WMR_BRIDGE_NAME, ignoreCase = true) == true
    }
    val WMR_STREAM_CHAR_UUID: UUID = UUID.fromString("0000ff11-0000-1000-8000-00805f9b34fb")
    val WMR_DECODED_CHAR_UUID: UUID = UUID.fromString("0000ff12-0000-1000-8000-00805f9b34fb")
    val WMR_BATCHED_CHAR_UUID: UUID = UUID.fromString("0000ff14-0000-1000-8000-00805f9b34fb")
    val WMR_ECHO_CHAR_UUID: UUID = UUID.fromString("0000ff15-0000-1000-8000-00805f9b34fb")
    val CCC_DESCRIPTOR_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    const val REQUESTED_MTU = 517

    const val WMR_ECHO_VERSION = 1
    const val WMR_ECHO_REQUEST_SIZE = 4
    const val WMR_ECHO_ANSWER_SIZE = 20

    const val WMR_BATCH_VERSION = 2
    const val WMR_BATCH_HEADER_SIZE = 2

    const val WMR_DECODED_SIZE = 56
    const val WMR_DECODED_VERSION = 1

    const val WMR_HAND_LEFT = 0
    const val WMR_HAND_RIGHT = 1
    const val WMR_NUM_CONTROLLERS = 2

    fun encodeEchoRequest(pingId: Int): ByteArray {
        val out = ByteArray(WMR_ECHO_REQUEST_SIZE)
        out[0] = WMR_ECHO_VERSION.toByte()
        out[1] = 0
        out[2] = (pingId and 0xFF).toByte()
        out[3] = ((pingId shr 8) and 0xFF).toByte()
        return out
    }

    data class EchoAnswer(
        val pingId: Int,
        val rxTimeUs: Long,
        val turnaroundUs: Long,
        val queueDepth: Int
    )

    sealed class EchoParseResult {
        data class Ok(val answer: EchoAnswer) : EchoParseResult()
        data class Error(val reason: String) : EchoParseResult()
    }

    fun parseEchoAnswer(bytes: ByteArray): EchoParseResult {
        if (bytes.size != WMR_ECHO_ANSWER_SIZE) {
            return EchoParseResult.Error("Wrong length: ${bytes.size} != $WMR_ECHO_ANSWER_SIZE")
        }
        val version = bytes[0].toInt() and 0xFF
        if (version != WMR_ECHO_VERSION) {
            return EchoParseResult.Error("Unknown echo version: $version")
        }
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val pingId = buffer.getShort(2).toInt() and 0xFFFF
        val rxTimeUs = buffer.getLong(4)
        val turnaroundUs = buffer.getInt(12).toLong() and 0xFFFFFFFFL
        val queueDepth = buffer.getShort(16).toInt() and 0xFFFF
        return EchoParseResult.Ok(
            EchoAnswer(
                pingId = pingId,
                rxTimeUs = rxTimeUs,
                turnaroundUs = turnaroundUs,
                queueDepth = queueDepth
            )
        )
    }

    data class DecodedRecord(
        val hand: Int,
        val flags: Int,
        val buttons: Int,
        val sequence: Long,
        val rxTimeUs: Long,
        val deviceTicks: Long
    )

    data class BatchParseResult(
        val records: List<DecodedRecord>,
        val parseErrors: Int = 0,
        val errorMessage: String? = null
    ) {
        val isOk: Boolean get() = errorMessage == null
    }

    fun parseDecodedBatch(bytes: ByteArray): BatchParseResult {
        if (bytes.size < WMR_BATCH_HEADER_SIZE + WMR_DECODED_SIZE) {
            return BatchParseResult(emptyList(), parseErrors = 1, errorMessage = "Batch too short: ${bytes.size}")
        }
        val version = bytes[0].toInt() and 0xFF
        if (version != WMR_BATCH_VERSION) {
            return BatchParseResult(emptyList(), parseErrors = 1, errorMessage = "Unknown batch version: $version")
        }
        val count = bytes[1].toInt() and 0xFF
        if (count < 1) {
            return BatchParseResult(emptyList(), parseErrors = 1, errorMessage = "Empty batch count: $count")
        }
        val expectedLength = WMR_BATCH_HEADER_SIZE + count * WMR_DECODED_SIZE
        if (bytes.size != expectedLength) {
            return BatchParseResult(emptyList(), parseErrors = 1, errorMessage = "Batch wrong length: ${bytes.size} != $expectedLength")
        }

        val records = ArrayList<DecodedRecord>(count)
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var parseErrors = 0
        for (i in 0 until count) {
            val offset = WMR_BATCH_HEADER_SIZE + i * WMR_DECODED_SIZE
            val recVersion = bytes[offset].toInt() and 0xFF
            val hand = bytes[offset + 1].toInt() and 0xFF
            if (recVersion != WMR_DECODED_VERSION || hand !in 0 until WMR_NUM_CONTROLLERS) {
                parseErrors++
                continue
            }
            val flags = bytes[offset + 2].toInt() and 0xFF
            val buttons = bytes[offset + 3].toInt() and 0xFF
            val sequence = buffer.getInt(offset + 4).toLong() and 0xFFFFFFFFL
            val rxTimeUs = buffer.getLong(offset + 8)
            val deviceTicks = buffer.getInt(offset + 16).toLong() and 0xFFFFFFFFL

            records.add(
                DecodedRecord(
                    hand = hand,
                    flags = flags,
                    buttons = buttons,
                    sequence = sequence,
                    rxTimeUs = rxTimeUs,
                    deviceTicks = deviceTicks
                )
            )
        }
        return BatchParseResult(records, parseErrors = parseErrors)
    }

    /**
     * `b - a` modulo 2^32, as a signed 32-bit value. 1 means consecutive.
     */
    fun sequenceDelta(a: Long, b: Long): Int = (((b - a) and 0xFFFFFFFFL).toInt())

    /**
     * `b - a` modulo 2^32, as unsigned 32-bit ticks.
     */
    fun tickDelta(a: Long, b: Long): Long = ((b - a) and 0xFFFFFFFFL)
}
