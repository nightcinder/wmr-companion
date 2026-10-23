import Foundation
import Combine

/// Telemetry record for one FF15 echo round trip.
public struct WMREchoLatencySample: Sendable {
    public let pingId: UInt16
    public let roundTripTimeMs: Double
    public let espTurnaroundUs: UInt32
    public let espQueueDepth: UInt16
    public let clientSendTimeNanos: UInt64
    public let clientRecvTimeNanos: UInt64

    public init(
        pingId: UInt16,
        roundTripTimeMs: Double,
        espTurnaroundUs: UInt32,
        espQueueDepth: UInt16,
        clientSendTimeNanos: UInt64,
        clientRecvTimeNanos: UInt64
    ) {
        self.pingId = pingId
        self.roundTripTimeMs = roundTripTimeMs
        self.espTurnaroundUs = espTurnaroundUs
        self.espQueueDepth = espQueueDepth
        self.clientSendTimeNanos = clientSendTimeNanos
        self.clientRecvTimeNanos = clientRecvTimeNanos
    }
}

/// Represents an active WMR Bridge session managing pipelines, echo testing, and decoded samples.
public final class WMRBridgeSession: @unchecked Sendable {
    public let bleManager: WMRBleCentralManager
    public let leftPipeline: WMRHandPipeline
    public let rightPipeline: WMRHandPipeline
    private let reassembler = WmrReassembler()

    private var cancellables = Set<AnyCancellable>()

    // Controller states
    public let leftStatePublisher = CurrentValueSubject<WMRControllerState, Never>(WMRControllerState(hand: .left))
    public let rightStatePublisher = CurrentValueSubject<WMRControllerState, Never>(WMRControllerState(hand: .right))

    // Echo latency tracking
    private var nextPingId: UInt16 = 1
    private var pendingPings: [UInt16: UInt64] = [:] // pingId -> sendTimestampNanos
    public let echoLatencyPublisher = PassthroughSubject<WMREchoLatencySample, Never>()

    // Config block tracking
    public let configWindowPublisher = PassthroughSubject<ConfigWindow, Never>()

    public init(
        bleManager: WMRBleCentralManager = WMRBleCentralManager(),
        leftPipeline: WMRHandPipeline? = nil,
        rightPipeline: WMRHandPipeline? = nil
    ) {
        self.bleManager = bleManager
        self.leftPipeline = leftPipeline ?? WMRHandPipeline(hand: .left)
        self.rightPipeline = rightPipeline ?? WMRHandPipeline(hand: .right)

        setupSubscriptions()
    }

    private func setupSubscriptions() {
        bleManager.notificationPublisher
            .sink { [weak self] notif in
                self?.handleNotification(notif)
            }
            .store(in: &cancellables)

        bleManager.statePublisher
            .sink { [weak self] state in
                if state == .disconnected {
                    self?.leftPipeline.reset()
                    self?.rightPipeline.reset()
                    self?.leftStatePublisher.send(WMRControllerState(hand: .left, isConnected: false))
                    self?.rightStatePublisher.send(WMRControllerState(hand: .right, isConnected: false))
                }
            }
            .store(in: &cancellables)
    }

    private func handleNotification(_ notif: WMRRawNotification) {
        switch notif.characteristicUUID {
        case WMRConstants.streamCharUUID:
            // FF11 raw fragmented stream
            let result = reassembler.push(notif.data)
            if case .frameComplete(_) = result {
                // Handled in reassembler
            }

        case WMRConstants.decodedCharUUID:
            // FF12 decoded record
            if case .success(let record) = parseDecodedRecord(notif.data) {
                dispatchRecord(record)
            }

        case WMRConstants.batchedCharUUID:
            // FF14 batched decoded records
            if case .success(let batch) = parseDecodedBatch(notif.data) {
                for record in batch {
                    dispatchRecord(record)
                }
            }

        case WMRConstants.echoCharUUID:
            // FF15 echo answer
            if case .success(let answer) = parseEchoAnswer(notif.data) {
                handleEchoAnswer(answer, arrivalNanos: notif.arrivalTimestampNanos)
            }

        case WMRConstants.configCharUUID:
            // FF13 config window
            if case .success(let window) = parseConfigWindow(notif.data) {
                configWindowPublisher.send(window)
            }

        default:
            break
        }
    }

    private func dispatchRecord(_ record: DecodedRecord) {
        let pipeline = (record.hand == .left) ? leftPipeline : rightPipeline
        let state = pipeline.push(record: record)
        if record.hand == .left {
            leftStatePublisher.send(state)
        } else {
            rightStatePublisher.send(state)
        }
    }

    // MARK: - Echo Latency Testing

    /// Sends an FF15 ping and records client timestamp.
    public func sendEchoPing() {
        let pingId = nextPingId
        nextPingId = (nextPingId == UInt16.max) ? 1 : (nextPingId + 1)

        let sendNanos = DispatchTime.now().uptimeNanoseconds
        pendingPings[pingId] = sendNanos

        let request = encodeEchoRequest(pingId: pingId)
        bleManager.sendEchoPing(data: request)
    }

    private func handleEchoAnswer(_ answer: EchoAnswer, arrivalNanos: UInt64) {
        guard let sendNanos = pendingPings.removeValue(forKey: answer.pingId) else { return }
        let roundTripNanos = (arrivalNanos >= sendNanos) ? (arrivalNanos - sendNanos) : 0
        let roundTripMs = Double(roundTripNanos) / 1_000_000.0

        let sample = WMREchoLatencySample(
            pingId: answer.pingId,
            roundTripTimeMs: roundTripMs,
            espTurnaroundUs: answer.turnaroundUs,
            espQueueDepth: answer.queueDepth,
            clientSendTimeNanos: sendNanos,
            clientRecvTimeNanos: arrivalNanos
        )
        echoLatencyPublisher.send(sample)
    }
}
