import Combine
import XCTest
import WMRCompanionKit
@testable import WMRVisionOSApp

@MainActor
private final class FakeCompanionBLEClient: CompanionBLEClient {
    let discovered = CurrentValueSubject<[WMRDiscoveredBridge], Never>([])
    let connection = CurrentValueSubject<WMRConnectionState, Never>(.disconnected)
    let echo = PassthroughSubject<WMREchoLatencySample, Never>()
    let left = PassthroughSubject<WMRControllerState, Never>()
    let right = PassthroughSubject<WMRControllerState, Never>()
    let errors = PassthroughSubject<String, Never>()
    let firmware = PassthroughSubject<WMRFirmwareVersion, Never>()

    private(set) var startedScanning = false
    private(set) var requestedModes: [WMRStreamMode] = []
    private(set) var pingCount = 0

    var discoveredBridgesPublisher: AnyPublisher<[WMRDiscoveredBridge], Never> {
        discovered.eraseToAnyPublisher()
    }

    var connectionStatePublisher: AnyPublisher<WMRConnectionState, Never> {
        connection.eraseToAnyPublisher()
    }

    var echoLatencyPublisher: AnyPublisher<WMREchoLatencySample, Never> {
        echo.eraseToAnyPublisher()
    }

    var leftControllerPublisher: AnyPublisher<WMRControllerState, Never> {
        left.eraseToAnyPublisher()
    }

    var rightControllerPublisher: AnyPublisher<WMRControllerState, Never> {
        right.eraseToAnyPublisher()
    }

    var streamErrorPublisher: AnyPublisher<String, Never> {
        errors.eraseToAnyPublisher()
    }

    var firmwareVersionPublisher: AnyPublisher<WMRFirmwareVersion, Never> {
        firmware.eraseToAnyPublisher()
    }

    func startScanning() {
        startedScanning = true
    }

    func stopScanning() {
        startedScanning = false
    }

    func connect(to bridge: WMRDiscoveredBridge) {}

    func disconnect() {}

    func setStreamMode(_ mode: WMRStreamMode) {
        requestedModes.append(mode)
    }

    func sendEchoPing() {
        pingCount += 1
    }

    func readFirmwareVersion() {}
}

@MainActor
final class CompanionDashboardModelTests: XCTestCase {
    func testScanningAndStreamControlsForwardToClient() {
        let client = FakeCompanionBLEClient()
        let model = CompanionDashboardModel(clientFactory: { client })

        model.startScanning()
        XCTAssertTrue(client.startedScanning)
        XCTAssertTrue(model.isScanning)

        model.stopScanning()
        XCTAssertFalse(client.startedScanning)
        XCTAssertFalse(model.isScanning)

        let modes: [WMRStreamMode] = [.rawFF11, .decodedFF12, .batchedFF14]
        for mode in modes {
            model.selectStreamMode(mode)
            XCTAssertEqual(model.streamMode, mode)
        }
        XCTAssertEqual(client.requestedModes, modes)

        model.sendPing()
        XCTAssertEqual(client.pingCount, 1)
    }

    func testEchoAndConnectionTelemetryPublish() async {
        let client = FakeCompanionBLEClient()
        let model = CompanionDashboardModel(clientFactory: { client })

        let ready = expectation(description: "connection ready")
        let echoDelivered = expectation(description: "echo telemetry")
        let subscriptions = [
            model.$connectionState.dropFirst().sink { state in
                if state == .ready { ready.fulfill() }
            },
            model.$latestEcho.dropFirst().sink { sample in
                if sample != nil { echoDelivered.fulfill() }
            },
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        client.connection.send(.ready)
        client.echo.send(
            WMREchoLatencySample(
                pingId: 7,
                totalRoundTripTimeMs: 12.5,
                netRoundTripTimeMs: 11.0,
                espRxTimeUs: 100,
                espTurnaroundUs: 1_500,
                espQueueDepth: 0,
                clientSendTimeNanos: 1_000,
                clientRecvTimeNanos: 13_500_000
            )
        )

        await fulfillment(of: [ready, echoDelivered], timeout: 2)

        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.latestEcho?.pingId, 7)
        XCTAssertEqual(model.latestEcho?.netRoundTripTimeMs ?? 0, 11.0, accuracy: 0.001)
    }

    func testControllerTelemetryReachesDashboardAndTracking() async {
        let client = FakeCompanionBLEClient()
        let model = CompanionDashboardModel(clientFactory: { client })

        let received = expectation(description: "left controller telemetry")
        let subscription = model.$leftController.dropFirst().sink { state in
            if state != nil { received.fulfill() }
        }
        defer { subscription.cancel() }

        client.left.send(WMRControllerState(hand: .left, isConnected: true, sequence: 42))
        await fulfillment(of: [received], timeout: 2)

        XCTAssertEqual(model.leftController?.hand, .left)
        XCTAssertEqual(model.leftController?.sequence, 42)
    }

    func testFirmwareVersionPublishes() async {
        let client = FakeCompanionBLEClient()
        let model = CompanionDashboardModel(clientFactory: { client })

        let received = expectation(description: "firmware version")
        let subscription = model.$firmwareVersion.dropFirst().sink { version in
            if version != nil { received.fulfill() }
        }
        defer { subscription.cancel() }

        client.firmware.send(WMRFirmwareVersion(features: .none, version: "1.2.3"))
        await fulfillment(of: [received], timeout: 2)

        XCTAssertEqual(model.firmwareVersion, "1.2.3")
    }
}
