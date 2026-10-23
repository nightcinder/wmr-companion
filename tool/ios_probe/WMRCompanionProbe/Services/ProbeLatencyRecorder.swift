import Foundation
import WMRCompanionKit

/// Latency and link-quality recorder matching the `wmr-latency` v2 schema.
/// Exports both JSON summary and echo CSV for cross-platform analysis against Android GATT probe and Flutter app.
public final class ProbeLatencyRecorder: @unchecked Sendable {
    public struct Config: Sendable {
        public var streamMode: WMRStreamMode = .batchedFF14
        public var pingIntervalMs: Int = 250
        public var dualBridge: Bool = false

        public init(streamMode: WMRStreamMode = .batchedFF14, pingIntervalMs: Int = 250, dualBridge: Bool = false) {
            self.streamMode = streamMode
            self.pingIntervalMs = pingIntervalMs
            self.dualBridge = dualBridge
        }
    }

    public let config: Config
    private var echoSamples: [WMREchoLatencySample] = []
    private var leftArrivalsNanos: [UInt64] = []
    private var rightArrivalsNanos: [UInt64] = []
    private let startTime: Date

    public init(config: Config = Config()) {
        self.config = config
        self.startTime = Date()
    }

    public func recordEcho(_ sample: WMREchoLatencySample) {
        echoSamples.append(sample)
    }

    public func recordArrival(hand: WMRHand, nanos: UInt64) {
        if hand == .left {
            leftArrivalsNanos.append(nanos)
        } else {
            rightArrivalsNanos.append(nanos)
        }
    }

    /// Generates echo CSV matching the format: `ping_id,sent_us,rtt_us,esp_rx_us,esp_turnaround_us,queue_depth`.
    public func exportEchoCSV() -> String {
        var lines = ["ping_id,sent_us,rtt_us,esp_rx_us,esp_turnaround_us,queue_depth"]
        for s in echoSamples {
            let sentUs = s.clientSendTimeNanos / 1000
            let rttUs = UInt32(s.roundTripTimeMs * 1000.0)
            lines.append("\(s.pingId),\(sentUs),\(rttUs),\(s.espTurnaroundUs),\(s.espTurnaroundUs),\(s.espQueueDepth)")
        }
        return lines.joined(separator: "\n")
    }

    /// Generates summary JSON matching `wmr-latency` v2 schema.
    public func exportSummaryJSON(leftStats: (lossPercent: Double, gaps: Int), rightStats: (lossPercent: Double, gaps: Int)) -> String {
        let rtts = echoSamples.map { $0.roundTripTimeMs }.sorted()
        let count = rtts.count

        func percentile(_ p: Double) -> Double {
            guard count > 0 else { return 0 }
            let index = min(Int(Double(count) * p), count - 1)
            return rtts[index]
        }

        let p50 = percentile(0.50)
        let p95 = percentile(0.95)
        let p99 = percentile(0.99)
        let minRtt = rtts.first ?? 0
        let maxRtt = rtts.last ?? 0

        let formatter = ISO8601DateFormatter()
        let timestampStr = formatter.string(from: startTime)

        let dict: [String: Any] = [
            "schema": "wmr-latency-v2",
            "platform": "iOS",
            "timestamp": timestampStr,
            "stream_mode": config.streamMode.description,
            "dual_bridge": config.dualBridge,
            "ping_interval_ms": config.pingIntervalMs,
            "echo": [
                "pings_sent": count,
                "pings_answered": count,
                "rtt_min_ms": minRtt,
                "rtt_p50_ms": p50,
                "rtt_p95_ms": p95,
                "rtt_p99_ms": p99,
                "rtt_max_ms": maxRtt
            ],
            "controllers": [
                "left": [
                    "loss_percent": leftStats.lossPercent,
                    "sequence_gaps": leftStats.gaps,
                    "records_received": leftArrivalsNanos.count
                ],
                "right": [
                    "loss_percent": rightStats.lossPercent,
                    "sequence_gaps": rightStats.gaps,
                    "records_received": rightArrivalsNanos.count
                ]
            ]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}
