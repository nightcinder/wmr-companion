package com.onyxlens.wmr.gattprobe

import java.util.Locale

object JsonWriter {

    fun toJsonString(report: LatencyReport): String {
        val sb = StringBuilder()
        sb.append("{\n")
        sb.append("  \"format\": \"${LatencyRecorder.LATENCY_FORMAT_NAME}\",\n")
        sb.append("  \"version\": ${LatencyRecorder.LATENCY_FORMAT_VERSION},\n")
        sb.append("  \"source\": \"wmr-gatt-probe (native Android)\",\n")
        sb.append("  \"started\": \"${report.started}\",\n")
        sb.append("  \"stream\": \"${report.stream}\",\n")
        sb.append("  \"duration_us\": ${report.durationUs},\n")

        // round_trip
        sb.append("  \"round_trip\": ")
        if (report.echo != null) {
            writeEchoSummary(sb, report.echo, "  ")
        } else {
            sb.append("{\n")
            sb.append("    \"measured\": false,\n")
            sb.append("    \"reason\": \"echo not used (needs the FF15 echo, WMR_Bridge #13)\"\n")
            sb.append("  }")
        }
        sb.append(",\n")

        // link
        sb.append("  \"link\": {\n")
        sb.append("    \"mtu\": ${report.link.mtu ?: "null"},\n")
        sb.append("    \"rssi_start_dbm\": ${report.link.rssiStart ?: "null"},\n")
        sb.append("    \"rssi_end_dbm\": ${report.link.rssiEnd ?: "null"},\n")
        sb.append("    \"connection_interval_us\": ${report.link.connectionIntervalUs ?: "null"},\n")
        sb.append("    \"phy\": ${report.link.phy?.let { "\"$it\"" } ?: "null"},\n")
        sb.append("    \"high_priority_requested\": ${report.link.highPriorityRequested ?: "null"}\n")
        sb.append("  },\n")

        // counters
        sb.append("  \"counters\": {\n")
        val counterEntries = report.counters.entries.toList()
        for (i in counterEntries.indices) {
            val entry = counterEntries[i]
            sb.append("    \"${entry.key}\": ${entry.value}")
            if (i < counterEntries.size - 1) sb.append(",")
            sb.append("\n")
        }
        sb.append("  },\n")

        sb.append("  \"rows_dropped\": ${report.rowsDropped},\n")
        sb.append("  \"mode_changed\": ${report.modeChanged},\n")

        // hands
        sb.append("  \"hands\": [\n")
        for (i in report.hands.indices) {
            writeHandSummary(sb, report.hands[i], "    ")
            if (i < report.hands.size - 1) sb.append(",")
            sb.append("\n")
        }
        sb.append("  ]\n")

        sb.append("}\n")
        return sb.toString()
    }

    private fun writePercentiles(sb: StringBuilder, p: UsPercentiles, indent: String) {
        sb.append("{\n")
        sb.append("$indent  \"count\": ${p.count},\n")
        sb.append("$indent  \"min_us\": ${p.min},\n")
        sb.append("$indent  \"p50_us\": ${p.p50},\n")
        sb.append("$indent  \"p90_us\": ${p.p90},\n")
        sb.append("$indent  \"p95_us\": ${p.p95},\n")
        sb.append("$indent  \"p99_us\": ${p.p99},\n")
        sb.append("$indent  \"max_us\": ${p.max}\n")
        sb.append("$indent}")
    }

    private fun writeEchoSummary(sb: StringBuilder, echo: EchoSummary, indent: String) {
        sb.append("{\n")
        sb.append("$indent  \"measured\": true,\n")
        sb.append("$indent  \"source\": \"FF15 echo\",\n")
        sb.append("$indent  \"sent\": ${echo.sent},\n")
        sb.append("$indent  \"answered\": ${echo.answered},\n")
        sb.append("$indent  \"timeouts\": ${echo.timeouts},\n")
        sb.append("$indent  \"failed_writes\": ${echo.failedWrites},\n")

        sb.append("$indent  \"rtt\": ")
        writePercentiles(sb, echo.rtt, "$indent  ")
        sb.append(",\n")

        sb.append("$indent  \"end_to_end\": ")
        writePercentiles(sb, echo.endToEnd, "$indent  ")
        sb.append(",\n")

        sb.append("$indent  \"turnaround\": ")
        writePercentiles(sb, echo.turnaround, "$indent  ")
        sb.append(",\n")

        sb.append("$indent  \"max_queue_depth\": ${echo.maxQueueDepth},\n")

        sb.append("$indent  \"counters\": {\n")
        val entries = echo.counters.entries.toList()
        for (i in entries.indices) {
            val e = entries[i]
            sb.append("$indent    \"${e.key}\": ${e.value}")
            if (i < entries.size - 1) sb.append(",")
            sb.append("\n")
        }
        sb.append("$indent  }")
        if (echo.pingIntervalUs != null) {
            sb.append(",\n$indent  \"ping_interval_us\": ${echo.pingIntervalUs}\n")
        } else {
            sb.append("\n")
        }
        sb.append("$indent}")
    }

    private fun writeHandSummary(sb: StringBuilder, h: LatencyHandSummary, indent: String) {
        val handName = when (h.hand) {
            Protocol.WMR_HAND_LEFT -> "LEFT"
            Protocol.WMR_HAND_RIGHT -> "RIGHT"
            else -> "HAND${h.hand}"
        }
        sb.append("$indent{\n")
        sb.append("$indent  \"hand\": \"$handName\",\n")
        sb.append("$indent  \"records\": ${h.records},\n")
        sb.append("$indent  \"arrivals\": ${h.arrivals},\n")
        sb.append("$indent  \"span_us\": ${h.spanUs},\n")
        sb.append("$indent  \"rate_per_s\": ${String.format(Locale.US, "%.2f", h.ratePerSecond)},\n")

        sb.append("$indent  \"inter_arrival\": ")
        writePercentiles(sb, h.interArrival, "$indent  ")
        sb.append(",\n")

        sb.append("$indent  \"stalls_over_${LatencyRecorder.LATENCY_STALL_US}us\": ${h.stalls},\n")
        sb.append("$indent  \"sequence_gaps\": ${h.sequenceGaps},\n")
        sb.append("$indent  \"sequence_loss\": ${String.format(Locale.US, "%.4f", h.sequenceLoss)},\n")
        sb.append("$indent  \"out_of_order\": ${h.outOfOrder},\n")

        sb.append("$indent  \"missing_from_ticks\": ${h.missingFromTicks ?: "null"},\n")
        sb.append("$indent  \"tick_loss\": ${h.tickLoss?.let { String.format(Locale.US, "%.4f", it) } ?: "null"},\n")
        sb.append("$indent  \"period_us\": ${h.periodUs ?: "null"},\n")

        sb.append("$indent  \"delay_above_window_min\": ")
        if (h.delay != null) {
            writePercentiles(sb, h.delay, "$indent  ")
        } else {
            sb.append("null")
        }
        sb.append(",\n")

        sb.append("$indent  \"delay_variation\": ")
        if (h.delayVariation != null) {
            writePercentiles(sb, h.delayVariation, "$indent  ")
        } else {
            sb.append("null")
        }
        sb.append("\n")

        sb.append("$indent}")
    }
}
