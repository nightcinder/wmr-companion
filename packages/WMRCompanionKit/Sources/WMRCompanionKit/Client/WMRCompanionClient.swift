import Foundation
import Combine

/// High-level client interface for the iOS companion application framework.
public final class WMRCompanionClient: @unchecked Sendable {
    public static let shared = WMRCompanionClient()

    public let session: WMRBridgeSession
    private var cancellables = Set<AnyCancellable>()

    @Published public private(set) var discoveredBridges: [WMRDiscoveredBridge] = []

    public init(session: WMRBridgeSession = WMRBridgeSession()) {
        self.session = session

        session.bleManager.discoveredBridgesPublisher
            .sink { [weak self] bridge in
                guard let self = self else { return }
                if !self.discoveredBridges.contains(where: { $0.id == bridge.id }) {
                    self.discoveredBridges.append(bridge)
                }
            }
            .store(in: &cancellables)
    }

    public var connectionStatePublisher: AnyPublisher<WMRConnectionState, Never> {
        session.bleManager.statePublisher.eraseToAnyPublisher()
    }

    public var leftControllerPublisher: AnyPublisher<WMRControllerState, Never> {
        session.leftStatePublisher.eraseToAnyPublisher()
    }

    public var rightControllerPublisher: AnyPublisher<WMRControllerState, Never> {
        session.rightStatePublisher.eraseToAnyPublisher()
    }

    public var echoLatencyPublisher: AnyPublisher<WMREchoLatencySample, Never> {
        session.echoLatencyPublisher.eraseToAnyPublisher()
    }

    public func startScanning() {
        discoveredBridges.removeAll()
        session.bleManager.startScanning()
    }

    public func stopScanning() {
        session.bleManager.stopScanning()
    }

    public func connect(to bridge: WMRDiscoveredBridge) {
        session.bleManager.connect(to: bridge)
    }

    public func disconnect() {
        session.bleManager.disconnect()
    }

    public func setStreamMode(_ mode: WMRStreamMode) {
        session.bleManager.setStreamMode(mode)
    }

    public func sendEchoPing() {
        session.sendEchoPing()
    }

    /// Reads controller config block over FF13 for specified hand and de-obfuscates with key.
    public func fetchCalibration(hand: WMRHand, monadoKey: Data) async throws -> ControllerCalibration {
        var cursorOffset: UInt32 = 0
        var accumulatedBlob = Data()
        var expectedTotal: UInt32 = 0
        var expectedCrc: UInt32 = 0

        // Step 1: Write cursor 0 to initiate read
        let cursorData = encodeConfigCursor(hand: hand, offset: 0)
        session.bleManager.writeConfigCursor(data: cursorData)
        session.bleManager.readConfigWindow()

        for await window in session.configWindowPublisher.values {
            guard window.hand == hand else { continue }
            guard window.state == .ready else {
                if window.state == .failed {
                    throw ConfigDecodeError.jsonParseError("Controller reports config state failed")
                }
                // Still reading, write cursor again
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                session.bleManager.writeConfigCursor(data: cursorData)
                session.bleManager.readConfigWindow()
                continue
            }

            expectedTotal = window.totalLen
            expectedCrc = window.crc32
            accumulatedBlob.append(window.data)
            cursorOffset += UInt32(window.data.count)

            if cursorOffset >= expectedTotal {
                break
            }

            // Request next chunk
            let nextCursor = encodeConfigCursor(hand: hand, offset: cursorOffset)
            session.bleManager.writeConfigCursor(data: nextCursor)
            session.bleManager.readConfigWindow()
        }

        // Verify CRC
        let computedCrc = crc32(accumulatedBlob)
        guard computedCrc == expectedCrc else {
            throw ConfigDecodeError.jsonParseError("CRC mismatch: expected \(expectedCrc), got \(computedCrc)")
        }

        // De-obfuscate and parse
        switch deobfuscateConfig(blob: accumulatedBlob, key: monadoKey) {
        case .success(let jsonString):
            switch parseControllerCalibration(jsonString: jsonString) {
            case .success(let calibration):
                return calibration
            case .failure(let err):
                throw err
            }
        case .failure(let err):
            throw err
        }
    }
}
