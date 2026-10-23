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

    public var streamErrorPublisher: AnyPublisher<String, Never> {
        session.bleManager.streamErrorPublisher.eraseToAnyPublisher()
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
    /// Implements bounded retries, subscription-first sequencing, and strict window validation.
    public func fetchCalibration(
        hand: WMRHand,
        monadoKey: Data,
        timeoutSeconds: TimeInterval = 10.0
    ) async throws -> ControllerCalibration {
        var cursorOffset: UInt32 = 0
        var accumulatedBlob = Data()
        var expectedTotal: UInt32 = 0
        var expectedCrc: UInt32 = 0
        var attempts = 0
        let maxAttempts = 20

        // Step 1: Subscribe to windows BEFORE initiating write to prevent race
        let windowStream = session.configWindowPublisher.values

        // Step 2: Write initial cursor
        let initialCursor = encodeConfigCursor(hand: hand, offset: 0)
        session.bleManager.writeConfigCursor(data: initialCursor)
        session.bleManager.readConfigWindow()

        let deadline = Date().addingTimeInterval(timeoutSeconds)

        for await window in windowStream {
            if Date() > deadline {
                throw ConfigDecodeError.jsonParseError("Timeout waiting for controller calibration")
            }

            guard window.hand == hand else { continue }

            switch window.state {
            case .ready:
                if accumulatedBlob.isEmpty {
                    expectedTotal = window.totalLen
                    expectedCrc = window.crc32
                    guard expectedTotal > WMRConstants.configSkipBytes else {
                        throw ConfigDecodeError.blockTooShort
                    }
                } else {
                    guard window.totalLen == expectedTotal, window.crc32 == expectedCrc else {
                        throw ConfigDecodeError.jsonParseError("Config block metadata changed mid-stream")
                    }
                }

                guard window.offset == cursorOffset else {
                    throw ConfigDecodeError.jsonParseError("Window offset mismatch: expected \(cursorOffset), got \(window.offset)")
                }

                accumulatedBlob.append(window.data)
                cursorOffset += UInt32(window.data.count)

                if cursorOffset >= expectedTotal {
                    // All chunks received
                    break
                }

                // Request next window
                let nextCursor = encodeConfigCursor(hand: hand, offset: cursorOffset)
                session.bleManager.writeConfigCursor(data: nextCursor)
                session.bleManager.readConfigWindow()

            case .failed:
                throw ConfigDecodeError.jsonParseError("Controller reports config state failed")

            case .reading, .notRead:
                attempts += 1
                if attempts > maxAttempts {
                    throw ConfigDecodeError.jsonParseError("Exceeded maximum read attempts waiting for config ready")
                }
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms wait
                session.bleManager.writeConfigCursor(data: encodeConfigCursor(hand: hand, offset: cursorOffset))
                session.bleManager.readConfigWindow()
            }

            if expectedTotal > 0 && cursorOffset >= expectedTotal {
                break
            }
        }

        // Verify CRC-32
        let computedCrc = crc32(accumulatedBlob)
        guard computedCrc == expectedCrc else {
            throw ConfigDecodeError.jsonParseError("CRC-32 mismatch: expected \(expectedCrc), got \(computedCrc)")
        }

        // De-obfuscate with Monado key table
        switch deobfuscateConfig(blob: accumulatedBlob, key: monadoKey) {
        case .success(let jsonString):
            switch parseControllerCalibration(jsonString: jsonString) {
            case .success(let calibration):
                // Configure calibration on pipeline
                let pipeline = (hand == .left) ? session.leftPipeline : session.rightPipeline
                pipeline.imuCalibration = WMRImuCalibration(calibration: calibration)
                return calibration
            case .failure(let err):
                throw err
            }
        case .failure(let err):
            throw err
        }
    }
}
