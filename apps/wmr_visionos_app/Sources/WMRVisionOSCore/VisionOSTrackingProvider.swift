import Foundation
import WMRCompanionKit

/// Supplies head and hand poses to the companion app.
///
/// The production implementation is ARKit on visionOS; the simulated
/// implementation keeps unit tests and non-visionOS builds free of ARKit.
public protocol VisionOSTrackingProvider: AnyObject {
    /// Most recent snapshot, or `nil` until the first update.
    var latestSnapshot: VisionOSTrackingSnapshot? { get }

    /// Starts producing snapshots.
    func start() async throws

    /// Stops producing snapshots and finishes every update stream.
    func stop()

    /// Snapshot updates, including the current value on subscription.
    func updates() -> AsyncStream<VisionOSTrackingSnapshot>
}

/// Deterministic provider used by tests and by previews without ARKit.
public final class SimulatedVisionOSTrackingProvider: VisionOSTrackingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: VisionOSTrackingSnapshot?
    private var continuations: [UUID: AsyncStream<VisionOSTrackingSnapshot>.Continuation] = [:]
    private var running = false

    public init(initialSnapshot: VisionOSTrackingSnapshot? = nil) {
        snapshot = initialSnapshot
    }

    public var latestSnapshot: VisionOSTrackingSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public func start() async throws {
        lock.lock()
        running = true
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        running = false
        let pending = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.finish()
        }
    }

    public func updates() -> AsyncStream<VisionOSTrackingSnapshot> {
        AsyncStream { continuation in
            lock.lock()
            if let current = snapshot {
                continuation.yield(current)
            }
            if running {
                let id = UUID()
                continuations[id] = continuation
                lock.unlock()
                continuation.onTermination = { [weak self] _ in
                    self?.removeContinuation(id)
                }
            } else {
                lock.unlock()
                continuation.finish()
            }
        }
    }

    /// Publishes a snapshot to `latestSnapshot` and every live stream.
    public func send(_ snapshot: VisionOSTrackingSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        let pending = Array(continuations.values)
        lock.unlock()
        for continuation in pending {
            continuation.yield(snapshot)
        }
    }

    /// Convenience for tests: one head pose plus an optional wrist pose.
    public func send(
        head pose: VisionOSPose,
        hand: VisionOSHand? = nil,
        wrist: VisionOSPose? = nil,
        timestamp: TimeInterval = 0
    ) {
        var snapshot = VisionOSTrackingSnapshot(timestamp: timestamp)
        snapshot.head = VisionOSHeadPose(pose: pose, isTracked: true, timestamp: timestamp)
        if let hand, let wrist {
            snapshot.hands[hand] = VisionOSHandPose(hand: hand, joints: [.wrist: wrist])
        }
        send(snapshot)
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

#if os(visionOS)
import ARKit
import QuartzCore
import simd

/// ARKit-backed provider for `WorldTrackingProvider` and `HandTrackingProvider`.
///
/// The anchor update streams are consumed continuously; each update is merged
/// into one snapshot and republished to `updates()` subscribers.
@available(visionOS 1.0, *)
public final class ARKitVisionOSTrackingProvider: VisionOSTrackingProvider, @unchecked Sendable {
    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let handTracking = HandTrackingProvider()

    private let lock = NSLock()
    private var snapshot: VisionOSTrackingSnapshot?
    private var continuations: [UUID: AsyncStream<VisionOSTrackingSnapshot>.Continuation] = [:]
    private var deviceTask: Task<Void, Never>?
    private var handTask: Task<Void, Never>?
    private var running = false

    public init() {}

    public var latestSnapshot: VisionOSTrackingSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    public func start() async throws {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        do {
            try await session.run([worldTracking, handTracking])
        } catch {
            lock.lock()
            running = false
            lock.unlock()
            throw error
        }

        deviceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.worldTracking.state == .running {
                    let now = CACurrentMediaTime()
                    if let anchor = self.worldTracking.queryDeviceAnchor(atTimestamp: now) {
                        let head = VisionOSHeadPose(
                            pose: Self.pose(from: anchor.originFromAnchorTransform),
                            isTracked: anchor.isTracked,
                            timestamp: now
                        )
                        self.merge { snapshot in
                            snapshot.head = head
                            snapshot.timestamp = max(snapshot.timestamp, now)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 16_666_667)
            }
        }

        handTask = Task { [weak self] in
            guard let self else { return }
            for await update in self.handTracking.anchorUpdates {
                if case .removed = update.event { continue }
                let anchor = update.anchor
                let hand: VisionOSHand = (anchor.chirality == .left) ? .left : .right
                var joints: [VisionOSHandJoint: VisionOSPose] = [:]
                if let skeleton = anchor.handSkeleton {
                    let anchorTransform = anchor.originFromAnchorTransform
                    for (jointName, arkitJoint) in Self.jointMap {
                        let joint = skeleton.joint(arkitJoint)
                        joints[jointName] = Self.pose(
                            from: anchorTransform * joint.anchorFromJointTransform
                        )
                    }
                }
                let handPose = VisionOSHandPose(hand: hand, joints: joints)
                self.merge { snapshot in
                    snapshot.hands[hand] = handPose
                    snapshot.timestamp = max(snapshot.timestamp, update.timestamp)
                }
            }
        }
    }

    public func stop() {
        deviceTask?.cancel()
        handTask?.cancel()
        deviceTask = nil
        handTask = nil
        session.stop()

        lock.lock()
        running = false
        let pending = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.finish()
        }
    }

    public func updates() -> AsyncStream<VisionOSTrackingSnapshot> {
        AsyncStream { continuation in
            lock.lock()
            if let current = snapshot {
                continuation.yield(current)
            }
            let id = UUID()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    private func merge(_ body: (inout VisionOSTrackingSnapshot) -> Void) {
        lock.lock()
        var current = snapshot ?? VisionOSTrackingSnapshot()
        body(&current)
        snapshot = current
        let pending = Array(continuations.values)
        lock.unlock()
        for continuation in pending {
            continuation.yield(current)
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }

    private static let jointMap: [(VisionOSHandJoint, HandSkeleton.JointName)] = [
        (.wrist, .wrist),
        (.thumbTip, .thumbTip),
        (.indexFingerTip, .indexFingerTip),
        (.middleFingerTip, .middleFingerTip)
    ]

    private static func pose(from transform: simd_float4x4) -> VisionOSPose {
        let quaternion = simd_quatf(transform)
        let orientation = WMRQuaternion(
            w: quaternion.real,
            x: quaternion.imag.x,
            y: quaternion.imag.y,
            z: quaternion.imag.z
        ).normalized()
        let position = WMRVector3(
            x: transform.columns.3.x,
            y: transform.columns.3.y,
            z: transform.columns.3.z
        )
        return VisionOSPose(position: position, orientation: orientation)
    }
}
#endif
