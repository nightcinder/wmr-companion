import Combine
import Foundation
import SwiftUI
import WMRCompanionKit
import WMRVisionOSCore

/// The BLE surface the dashboard drives.
///
/// `WMRCompanionClient` provides every operation directly. Keeping the surface
/// behind a protocol lets the dashboard model be tested without starting a
/// real `CBCentralManager`, which needs Bluetooth permission and hardware.
@MainActor
public protocol CompanionBLEClient: AnyObject {
    var discoveredBridgesPublisher: AnyPublisher<[WMRDiscoveredBridge], Never> { get }
    var connectionStatePublisher: AnyPublisher<WMRConnectionState, Never> { get }
    var echoLatencyPublisher: AnyPublisher<WMREchoLatencySample, Never> { get }
    var leftControllerPublisher: AnyPublisher<WMRControllerState, Never> { get }
    var rightControllerPublisher: AnyPublisher<WMRControllerState, Never> { get }
    var streamErrorPublisher: AnyPublisher<String, Never> { get }
    var firmwareVersionPublisher: AnyPublisher<WMRFirmwareVersion, Never> { get }

    func startScanning()
    func stopScanning()
    func connect(to bridge: WMRDiscoveredBridge)
    func disconnect()
    func setStreamMode(_ mode: WMRStreamMode)
    func sendEchoPing()
    func readFirmwareVersion()
}

/// Production adapter over `WMRCompanionKit`'s `WMRCompanionClient`.
@MainActor
public final class WMRCompanionBLEClient: CompanionBLEClient {
    private let client: WMRCompanionClient

    public init(client: WMRCompanionClient = WMRCompanionClient()) {
        self.client = client
    }

    public var discoveredBridgesPublisher: AnyPublisher<[WMRDiscoveredBridge], Never> {
        client.discoveredBridgesPublisher
    }

    public var connectionStatePublisher: AnyPublisher<WMRConnectionState, Never> {
        client.connectionStatePublisher
    }

    public var echoLatencyPublisher: AnyPublisher<WMREchoLatencySample, Never> {
        client.echoLatencyPublisher
    }

    public var leftControllerPublisher: AnyPublisher<WMRControllerState, Never> {
        client.leftControllerPublisher
    }

    public var rightControllerPublisher: AnyPublisher<WMRControllerState, Never> {
        client.rightControllerPublisher
    }

    public var streamErrorPublisher: AnyPublisher<String, Never> {
        client.streamErrorPublisher
    }

    public var firmwareVersionPublisher: AnyPublisher<WMRFirmwareVersion, Never> {
        client.firmwareVersionPublisher
    }

    public func startScanning() {
        client.startScanning()
    }

    public func stopScanning() {
        client.stopScanning()
    }

    public func connect(to bridge: WMRDiscoveredBridge) {
        client.connect(to: bridge)
    }

    public func disconnect() {
        client.disconnect()
    }

    public func setStreamMode(_ mode: WMRStreamMode) {
        client.setStreamMode(mode)
    }

    public func sendEchoPing() {
        client.sendEchoPing()
    }

    public func readFirmwareVersion() {
        client.readFirmwareVersion()
    }
}

/// State behind `CompanionDashboardView`: bridge discovery, connection, stream
/// selection, FF15 latency and controller telemetry.
@MainActor
public final class CompanionDashboardModel: ObservableObject {
    @Published public private(set) var bridges: [WMRDiscoveredBridge] = []
    @Published public private(set) var connectionState: WMRConnectionState = .disconnected
    @Published public private(set) var latestEcho: WMREchoLatencySample?
    @Published public private(set) var streamError: String?
    @Published public private(set) var firmwareVersion: String?
    @Published public private(set) var leftController: WMRControllerState?
    @Published public private(set) var rightController: WMRControllerState?
    @Published public private(set) var streamMode: WMRStreamMode = .batchedFF14
    @Published public private(set) var isScanning = false

    /// Tracking fusion for the `ImmersiveSpace` view.
    public let tracking: VisionOSCompanionViewModel

    private let client: any CompanionBLEClient
    private var cancellables = Set<AnyCancellable>()

    public convenience init() {
        self.init(clientFactory: { WMRCompanionBLEClient() })
    }

    public init(
        clientFactory: () -> any CompanionBLEClient,
        tracking: VisionOSCompanionViewModel? = nil
    ) {
        let client = clientFactory()
        self.client = client
        self.tracking = tracking ?? VisionOSCompanionViewModel()
        subscribe(to: client)
    }

    public var connectionDescription: String {
        switch connectionState {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .discoveringServices: return "Discovering services"
        case .ready: return "Ready"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    public var isConnected: Bool {
        connectionState == .ready
    }

    public func startScanning() {
        streamError = nil
        bridges.removeAll()
        isScanning = true
        client.startScanning()
    }

    public func stopScanning() {
        isScanning = false
        client.stopScanning()
    }

    public func connect(to bridge: WMRDiscoveredBridge) {
        streamError = nil
        client.connect(to: bridge)
    }

    public func disconnect() {
        isScanning = false
        client.disconnect()
    }

    public func selectStreamMode(_ mode: WMRStreamMode) {
        streamMode = mode
        client.setStreamMode(mode)
    }

    public func sendPing() {
        client.sendEchoPing()
    }

    public func readFirmwareVersion() {
        client.readFirmwareVersion()
    }

    /// Starts ARKit head/hand tracking on visionOS. A no-op where the package
    /// has no tracking provider, such as the macOS CI runner.
    public func startTracking() async {
        try? await tracking.startTracking()
    }

    public func stopTracking() {
        tracking.stopTracking()
    }

    private func subscribe(to client: any CompanionBLEClient) {
        client.discoveredBridgesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bridges in
                Task { @MainActor in
                    self?.bridges = bridges
                }
            }
            .store(in: &cancellables)

        client.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor in
                    self?.connectionState = state
                    if state != .scanning {
                        self?.isScanning = false
                    }
                }
            }
            .store(in: &cancellables)

        client.echoLatencyPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                Task { @MainActor in
                    self?.latestEcho = sample
                }
            }
            .store(in: &cancellables)

        client.leftControllerPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor in
                    self?.leftController = state
                    self?.tracking.updateControllerState(state)
                }
            }
            .store(in: &cancellables)

        client.rightControllerPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor in
                    self?.rightController = state
                    self?.tracking.updateControllerState(state)
                }
            }
            .store(in: &cancellables)

        client.streamErrorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                Task { @MainActor in
                    self?.streamError = message
                }
            }
            .store(in: &cancellables)

        client.firmwareVersionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] version in
                Task { @MainActor in
                    self?.firmwareVersion = version.version
                }
            }
            .store(in: &cancellables)
    }
}

/// SwiftUI dashboard for the visionOS companion: scan/connect, stream mode,
/// FF15 latency and controller telemetry.
public struct CompanionDashboardView: View {
    @ObservedObject private var model: CompanionDashboardModel

    #if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif

    public init(model: CompanionDashboardModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Form {
                connectionSection
                streamSection
                telemetrySection
                spatialSection
            }
            .navigationTitle("WMR Companion")
        }
        .task {
            await model.startTracking()
        }
        .onDisappear {
            model.stopTracking()
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section("Bridge") {
            LabeledContent("Status", value: model.connectionDescription)

            if model.isScanning {
                Button("Stop Scanning") { model.stopScanning() }
            } else {
                Button("Scan for Bridges") { model.startScanning() }
            }

            ForEach(model.bridges) { bridge in
                HStack {
                    VStack(alignment: .leading) {
                        Text(bridge.name)
                        Text("\(bridge.rssi) dBm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") { model.connect(to: bridge) }
                }
            }

            if model.isConnected {
                Button("Disconnect", role: .destructive) { model.disconnect() }
            }
        }
    }

    @ViewBuilder
    private var streamSection: some View {
        Section("Stream") {
            Picker(
                "Mode",
                selection: Binding(
                    get: { model.streamMode },
                    set: { model.selectStreamMode($0) }
                )
            ) {
                ForEach(WMRStreamMode.allCases, id: \.self) { mode in
                    Text(mode.description).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Button("Send FF15 Ping") { model.sendPing() }
                .disabled(!model.isConnected)

            if let echo = model.latestEcho {
                LabeledContent(
                    "Round trip",
                    value: String(
                        format: "%.2f ms net (%.2f ms total, ping %d)",
                        echo.netRoundTripTimeMs,
                        echo.totalRoundTripTimeMs,
                        Int(echo.pingId)
                    )
                )
            }

            if let firmwareVersion = model.firmwareVersion {
                LabeledContent("Firmware", value: firmwareVersion)
            }

            if let error = model.streamError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var telemetrySection: some View {
        Section("Controllers") {
            controllerRow(title: "Left", state: model.leftController)
            controllerRow(title: "Right", state: model.rightController)
        }
    }

    private func controllerRow(title: String, state: WMRControllerState?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(controllerDescription(state))
                .foregroundStyle(.secondary)
        }
    }

    private func controllerDescription(_ state: WMRControllerState?) -> String {
        guard let state else { return "No data" }
        let link = state.isConnected ? "connected" : "idle"
        return String(
            format: "%@ · battery %d%% · %.0f Hz",
            link,
            Int(state.battery),
            state.packetRateHz
        )
    }

    @ViewBuilder
    private var spatialSection: some View {
        Section("6DoF") {
            #if os(visionOS)
            Button("Open Immersive Space") {
                Task {
                    _ = await openImmersiveSpace(id: ControllerImmersiveSpace.id)
                }
            }
            Button("Close Immersive Space") {
                Task {
                    await dismissImmersiveSpace()
                }
            }
            #else
            Text("RealityKit ImmersiveSpace visualization runs on visionOS.")
                .foregroundStyle(.secondary)
            #endif
        }
    }
}
