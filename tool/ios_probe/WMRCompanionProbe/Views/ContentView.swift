import SwiftUI
import Combine
import WMRCompanionKit

public struct ContentView: View {
    @StateObject private var viewModel = ProbeViewModel()

    public init() {}

    public var body: some View {
        NavigationView {
            Form {
                // MARK: - Connection Section
                Section(header: Text("Connection")) {
                    HStack {
                        Text("Status:")
                        Spacer()
                        Text(viewModel.statusText)
                            .foregroundColor(viewModel.statusColor)
                            .bold()
                    }

                    if viewModel.connectionState == .disconnected {
                        Button(action: {
                            if viewModel.isScanning {
                                viewModel.stopScan()
                            } else {
                                viewModel.startScan()
                            }
                        }) {
                            Text(viewModel.isScanning ? "Stop Scanning" : "Scan for WMR Bridge")
                        }

                        ForEach(viewModel.discoveredBridges) { bridge in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(bridge.name).font(.headline)
                                    Text("RSSI: \(bridge.rssi) dBm").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Connect") {
                                    viewModel.connect(to: bridge)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    } else {
                        Button("Disconnect", role: .destructive) {
                            viewModel.disconnect()
                        }
                    }
                }

                // MARK: - Stream Mode Section
                if viewModel.connectionState == .ready {
                    Section(header: Text("Stream Mode")) {
                        Picker("Mode", selection: $viewModel.streamMode) {
                            ForEach(WMRStreamMode.allCases, id: \.self) { mode in
                                Text(mode.description).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: viewModel.streamMode) { newMode in
                            viewModel.setStreamMode(newMode)
                        }
                    }

                    // MARK: - Latency Echo Section
                    Section(header: Text("FF15 Echo Latency Probe")) {
                        Picker("Interval", selection: $viewModel.pingIntervalMs) {
                            Text("50 ms").tag(50)
                            Text("250 ms").tag(250)
                            Text("1000 ms").tag(1000)
                        }
                        .pickerStyle(.segmented)

                        Toggle("Periodic Pings", isOn: $viewModel.periodicPingsEnabled)

                        HStack {
                            VStack(alignment: .leading) {
                                Text("Total RTT p50:").font(.caption).foregroundColor(.secondary)
                                Text(String(format: "%.1f ms", viewModel.p50RTT)).bold()
                            }
                            Spacer()
                            VStack(alignment: .leading) {
                                Text("Net RTT p50:").font(.caption).foregroundColor(.secondary)
                                Text(String(format: "%.1f ms", viewModel.p50NetRTT)).bold()
                            }
                            Spacer()
                            VStack(alignment: .leading) {
                                Text("Turnaround:").font(.caption).foregroundColor(.secondary)
                                Text(String(format: "%.2f ms", Double(viewModel.lastTurnaroundUs) / 1000.0)).bold()
                            }
                        }

                        Button("Send Single Ping") {
                            viewModel.sendSinglePing()
                        }
                    }

                    // MARK: - Controllers Telemetry
                    Section(header: Text("Controllers (3DoF Orientation & Inputs)")) {
                        ControllerTelemetryView(state: viewModel.leftState, label: "Left Controller")
                        ControllerTelemetryView(state: viewModel.rightState, label: "Right Controller")
                    }

                    // MARK: - Export Section
                    Section(header: Text("Data Export")) {
                        Button("Share Latency Summary (JSON)") {
                            viewModel.shareJSON()
                        }
                        Button("Share Echo Log (CSV)") {
                            viewModel.shareCSV()
                        }
                    }
                }
            }
            .navigationTitle("WMR Companion Probe")
        }
    }
}

struct ControllerTelemetryView: View {
    let state: WMRControllerState
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                Text(state.isConnected ? "Active" : "Inactive")
                    .foregroundColor(state.isConnected ? .green : .secondary)
                    .font(.caption)
            }

            if state.isConnected {
                Text(String(format: "Euler: Roll %.1f° | Pitch %.1f° | Yaw %.1f°", state.euler.roll, state.euler.pitch, state.euler.yaw))
                    .font(.subheadline)
                Text(String(format: "Rate: %.1f Hz | Loss: %.1f%% | Gaps: %d", state.packetRateHz, state.lossPercent, state.sequenceGaps))
                    .font(.caption).foregroundColor(.secondary)
                Text("Buttons: \(state.buttons.description)")
                    .font(.caption).foregroundColor(.secondary)
                Text("Trigger: \(state.trigger)/255 | Stick: (\(state.stick.x), \(state.stick.y))")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

final class ProbeViewModel: ObservableObject {
    private let client = WMRCompanionClient.shared
    private var cancellables = Set<AnyCancellable>()
    private var pingTimer: Timer?
    private let recorder = ProbeLatencyRecorder()

    @Published var connectionState: WMRConnectionState = .disconnected
    @Published var isScanning: Bool = false
    @Published var discoveredBridges: [WMRDiscoveredBridge] = []
    @Published var streamMode: WMRStreamMode = .batchedFF14
    @Published var pingIntervalMs: Int = 250
    @Published var periodicPingsEnabled: Bool = false {
        didSet { updatePingTimer() }
    }

    @Published var leftState = WMRControllerState(hand: .left)
    @Published var rightState = WMRControllerState(hand: .right)

    @Published var p50RTT: Double = 0
    @Published var p50NetRTT: Double = 0
    @Published var p95RTT: Double = 0
    @Published var lastTurnaroundUs: UInt32 = 0
    private var rttHistory: [Double] = []
    private var netRttHistory: [Double] = []

    init() {
        setupBindings()
    }

    private func setupBindings() {
        client.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.isScanning = (state == .scanning)
            }
            .store(in: &cancellables)

        client.$discoveredBridges
            .receive(on: DispatchQueue.main)
            .assign(to: &$discoveredBridges)

        client.leftControllerPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.leftState = state
                if state.isConnected {
                    self?.recorder.recordArrival(hand: .left, nanos: DispatchTime.now().uptimeNanoseconds)
                }
            }
            .store(in: &cancellables)

        client.rightControllerPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.rightState = state
                if state.isConnected {
                    self?.recorder.recordArrival(hand: .right, nanos: DispatchTime.now().uptimeNanoseconds)
                }
            }
            .store(in: &cancellables)

        client.echoLatencyPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                self?.handleEchoSample(sample)
            }
            .store(in: &cancellables)
    }

    var statusText: String {
        switch connectionState {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .discoveringServices: return "Discovering Services..."
        case .ready: return "Ready"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    var statusColor: Color {
        switch connectionState {
        case .ready: return .green
        case .scanning, .connecting, .discoveringServices: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    func startScan() { client.startScanning() }
    func stopScan() { client.stopScanning() }
    func connect(to bridge: WMRDiscoveredBridge) { client.connect(to: bridge) }
    func disconnect() { client.disconnect() }
    func setStreamMode(_ mode: WMRStreamMode) { client.setStreamMode(mode) }

    func sendSinglePing() {
        recorder.recordPingSent()
        client.sendEchoPing()
    }

    private func handleEchoSample(_ sample: WMREchoLatencySample) {
        recorder.recordEcho(sample)
        lastTurnaroundUs = sample.espTurnaroundUs
        rttHistory.append(sample.totalRoundTripTimeMs)
        netRttHistory.append(sample.netRoundTripTimeMs)

        if rttHistory.count > 100 { rttHistory.removeFirst() }
        if netRttHistory.count > 100 { netRttHistory.removeFirst() }

        let sorted = rttHistory.sorted()
        let sortedNet = netRttHistory.sorted()
        let count = sorted.count
        if count > 0 {
            p50RTT = sorted[Int(Double(count) * 0.50)]
            p50NetRTT = sortedNet[Int(Double(count) * 0.50)]
            p95RTT = sorted[min(Int(Double(count) * 0.95), count - 1)]
        }
    }

    private func updatePingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
        guard periodicPingsEnabled else { return }
        let interval = Double(pingIntervalMs) / 1000.0
        pingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.recorder.recordPingSent()
            self?.client.sendEchoPing()
        }
    }

    func shareJSON() {
        let json = recorder.exportSummaryJSON(
            leftStats: (leftState.lossPercent, leftState.sequenceGaps),
            rightStats: (rightState.lossPercent, rightState.sequenceGaps)
        )
        shareText(json)
    }

    func shareCSV() {
        let csv = recorder.exportEchoCSV()
        shareText(csv)
    }

    private func shareText(_ text: String) {
        #if canImport(UIKit)
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(av, animated: true)
        }
        #endif
    }
}
