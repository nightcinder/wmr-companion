import Foundation
import WMRCompanionKit

/// A rigid pose in the visionOS world frame: meters and a unit quaternion.
public struct VisionOSPose: Equatable, Sendable {
    public var position: WMRVector3
    public var orientation: WMRQuaternion

    public init(
        position: WMRVector3 = .zero,
        orientation: WMRQuaternion = .identity
    ) {
        self.position = position
        self.orientation = orientation
    }

    public static let identity = VisionOSPose()
}

/// The tracked hand a pose belongs to.
public enum VisionOSHand: String, CaseIterable, Sendable {
    case left
    case right

    public init(_ hand: WMRHand) {
        self = (hand == .left) ? .left : .right
    }

    public var wmrHand: WMRHand {
        (self == .left) ? .left : .right
    }
}

/// The subset of ARKit hand skeleton joints the companion app consumes.
public enum VisionOSHandJoint: String, CaseIterable, Sendable {
    case wrist
    case thumbTip
    case indexFingerTip
    case middleFingerTip
}

/// Joined hand pose from `HandTrackingProvider`, anchored on the wrist.
public struct VisionOSHandPose: Equatable, Sendable {
    public var hand: VisionOSHand
    public var joints: [VisionOSHandJoint: VisionOSPose]

    public init(
        hand: VisionOSHand,
        joints: [VisionOSHandJoint: VisionOSPose] = [:]
    ) {
        self.hand = hand
        self.joints = joints
    }

    /// The wrist pose, which supplies the translational half of controller 6DoF.
    public var wrist: VisionOSPose? {
        joints[.wrist]
    }
}

/// Head pose from `WorldTrackingProvider` (or its simulated stand-in).
public struct VisionOSHeadPose: Equatable, Sendable {
    public var pose: VisionOSPose
    public var isTracked: Bool
    public var timestamp: TimeInterval

    public init(
        pose: VisionOSPose = .identity,
        isTracked: Bool = false,
        timestamp: TimeInterval = 0
    ) {
        self.pose = pose
        self.isTracked = isTracked
        self.timestamp = timestamp
    }
}

/// One world snapshot produced by a tracking provider.
public struct VisionOSTrackingSnapshot: Equatable, Sendable {
    public var head: VisionOSHeadPose?
    public var hands: [VisionOSHand: VisionOSHandPose]
    public var timestamp: TimeInterval

    public init(
        head: VisionOSHeadPose? = nil,
        hands: [VisionOSHand: VisionOSHandPose] = [:],
        timestamp: TimeInterval = 0
    ) {
        self.head = head
        self.hands = hands
        self.timestamp = timestamp
    }

    public func wrist(for hand: WMRHand) -> VisionOSPose? {
        hands[VisionOSHand(hand)]?.wrist
    }
}

/// Where a composed controller pose came from.
public enum VisionOSPoseSource: String, Sendable {
    /// Hand-tracking wrist position composed with the bridge's fused orientation.
    case composed
    /// Provided directly by a simulated provider.
    case simulated
}

/// Six-degree-of-freedom controller pose consumed by the visionOS app.
public struct VisionOSControllerPose: Equatable, Sendable {
    public var hand: WMRHand
    public var pose: VisionOSPose
    public var source: VisionOSPoseSource
    public var isTracked: Bool
    public var timestamp: TimeInterval

    public init(
        hand: WMRHand,
        pose: VisionOSPose,
        source: VisionOSPoseSource = .composed,
        isTracked: Bool = true,
        timestamp: TimeInterval = 0
    ) {
        self.hand = hand
        self.pose = pose
        self.source = source
        self.isTracked = isTracked
        self.timestamp = timestamp
    }
}

/// Combines a tracked wrist position with `WMRCompanionKit`'s 3DoF controller pose.
///
/// The wrist supplies translation; the bridge's fused quaternion supplies
/// orientation. `wristOffset` is the fixed controller grip relative to the
/// wrist and is rotated into world space by the wrist orientation.
public struct VisionOSControllerPoseComposer: Sendable {
    public var wristOffset: VisionOSPose

    public init(wristOffset: VisionOSPose = VisionOSControllerPoseComposer.defaultWristOffset) {
        self.wristOffset = wristOffset
    }

    /// Grip roughly 8 cm in front of the wrist along visionOS -Z.
    public static let defaultWristOffset = VisionOSPose(
        position: WMRVector3(x: 0, y: 0, z: -0.08)
    )

    public func compose(
        hand: WMRHand,
        wrist: VisionOSPose,
        controllerOrientation: WMRQuaternion,
        timestamp: TimeInterval = 0
    ) -> VisionOSControllerPose {
        let offsetPosition = wrist.orientation.rotated(wristOffset.position)
        let position = wrist.position + offsetPosition
        let orientation = (controllerOrientation * wristOffset.orientation).normalized()

        return VisionOSControllerPose(
            hand: hand,
            pose: VisionOSPose(position: position, orientation: orientation),
            source: .composed,
            isTracked: true,
            timestamp: timestamp
        )
    }
}

extension WMRQuaternion {
    /// Rotates a vector by this quaternion (`q * v * q^-1`).
    public func rotated(_ vector: WMRVector3) -> WMRVector3 {
        let q = normalized()
        let u = WMRVector3(x: q.x, y: q.y, z: q.z)
        let uv = u.cross(vector)
        let uuv = u.cross(uv)
        return vector + (uv * (2 * q.w)) + (uuv * 2)
    }
}
