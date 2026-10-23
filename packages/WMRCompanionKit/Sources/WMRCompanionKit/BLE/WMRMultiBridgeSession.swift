import Foundation
import Combine

/// Multi-bridge coordinator for concurrent dual-ESP32 setups (e.g. Left Bridge + Right Bridge).
/// Eliminates upstream Classic Bluetooth contention on single ESP32s.
public final class WMRMultiBridgeSession: @unchecked Sendable {
    public let leftBridgeSession: WMRBridgeSession
    public let rightBridgeSession: WMRBridgeSession

    private var cancellables = Set<AnyCancellable>()

    public let leftStatePublisher = CurrentValueSubject<WMRControllerState, Never>(WMRControllerState(hand: .left))
    public let rightStatePublisher = CurrentValueSubject<WMRControllerState, Never>(WMRControllerState(hand: .right))
    public let combinedLatencyPublisher = PassthroughSubject<(hand: WMRHand, sample: WMREchoLatencySample), Never>()

    public init(
        leftBridgeSession: WMRBridgeSession = WMRBridgeSession(),
        rightBridgeSession: WMRBridgeSession = WMRBridgeSession()
    ) {
        self.leftBridgeSession = leftBridgeSession
        self.rightBridgeSession = rightBridgeSession

        // Forward left bridge left hand state
        leftBridgeSession.leftStatePublisher
            .sink { [weak self] state in
                self?.leftStatePublisher.send(state)
            }
            .store(in: &cancellables)

        // Forward right bridge right hand state
        rightBridgeSession.rightStatePublisher
            .sink { [weak self] state in
                self?.rightStatePublisher.send(state)
            }
            .store(in: &cancellables)

        // Forward latency samples
        leftBridgeSession.echoLatencyPublisher
            .sink { [weak self] sample in
                self?.combinedLatencyPublisher.send((hand: .left, sample: sample))
            }
            .store(in: &cancellables)

        rightBridgeSession.echoLatencyPublisher
            .sink { [weak self] sample in
                self?.combinedLatencyPublisher.send((hand: .right, sample: sample))
            }
            .store(in: &cancellables)
    }

    public func setStreamMode(_ mode: WMRStreamMode) {
        leftBridgeSession.bleManager.setStreamMode(mode)
        rightBridgeSession.bleManager.setStreamMode(mode)
    }

    public func sendEchoPings() {
        leftBridgeSession.sendEchoPing()
        rightBridgeSession.sendEchoPing()
    }
}
