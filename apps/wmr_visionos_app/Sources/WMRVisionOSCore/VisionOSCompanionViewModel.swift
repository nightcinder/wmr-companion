import Combine
import Foundation
import WMRCompanionKit

/// Glue between `WMRCompanionKit` controller state and visionOS tracking.
///
/// The bridge reports a 3DoF orientation from its IMU; ARKit reports where the
/// wrist is. This view model joins them into a tracked 6DoF controller pose per
/// hand and publishes the latest head, hand and controller state.
public final class VisionOSCompanionViewModel: ObservableObject {
    @Published public private(set) var headPose: VisionOSHeadPose?
    @Published public private(set) var trackingSnapshot = VisionOSTrackingSnapshot()
    @Published public private(set) var leftControllerPose: VisionOSControllerPose?
    @Published public private(set) var rightControllerPose: VisionOSControllerPose?

    public let composer: VisionOSControllerPoseComposer
    public let provider: VisionOSTrackingProvider?

    private var controllerStates: [WMRHand: WMRControllerState] = [:]
    private var trackingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(
        composer: VisionOSControllerPoseComposer = VisionOSControllerPoseComposer(),
        provider: VisionOSTrackingProvider? = nil
    ) {
        self.composer = composer
        self.provider = provider
    }

    deinit {
        trackingTask?.cancel()
        provider?.stop()
    }

    /// Starts the configured tracking provider and consumes its updates.
    public func startTracking() async throws {
        guard let provider else { return }
        try await provider.start()
        trackingTask?.cancel()
        trackingTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in provider.updates() {
                self.ingest(snapshot)
            }
        }
    }

    public func stopTracking() {
        trackingTask?.cancel()
        trackingTask = nil
        provider?.stop()
    }

    /// Applies a world snapshot and recomposes every hand with a live wrist.
    public func ingest(_ snapshot: VisionOSTrackingSnapshot) {
        trackingSnapshot = snapshot
        headPose = snapshot.head
        leftControllerPose = compose(hand: .left)
        rightControllerPose = compose(hand: .right)
    }

    /// Feeds one `WMRCompanionKit` controller update into the fusion.
    ///
    /// Returns the composed pose, or `nil` when the controller is disconnected
    /// or its hand has no tracked wrist yet.
    @discardableResult
    public func updateControllerState(_ state: WMRControllerState) -> VisionOSControllerPose? {
        controllerStates[state.hand] = state
        let pose = compose(hand: state.hand)
        set(pose, for: state.hand)
        return pose
    }

    /// Subscribes to the live controller publishers of a `WMRCompanionKit` client.
    public func bind(to client: WMRCompanionClient) {
        client.leftControllerPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateControllerState(state)
            }
            .store(in: &cancellables)

        client.rightControllerPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateControllerState(state)
            }
            .store(in: &cancellables)
    }

    private func compose(hand: WMRHand) -> VisionOSControllerPose? {
        guard
            let state = controllerStates[hand],
            state.isConnected,
            let wrist = trackingSnapshot.wrist(for: hand)
        else {
            return nil
        }

        let orientation = WMRQuaternion(
            w: state.orientation.w,
            x: state.orientation.x,
            y: state.orientation.y,
            z: state.orientation.z
        )

        return composer.compose(
            hand: hand,
            wrist: wrist,
            controllerOrientation: orientation,
            timestamp: trackingSnapshot.timestamp
        )
    }

    private func set(_ pose: VisionOSControllerPose?, for hand: WMRHand) {
        switch hand {
        case .left:
            leftControllerPose = pose
        case .right:
            rightControllerPose = pose
        }
    }
}
