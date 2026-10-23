import Foundation

/// A unit quaternion representing 3D spatial rotation (w + xi + yj + zk).
public struct WMRQuaternion: Equatable, Sendable {
    public var w: Float
    public var x: Float
    public var y: Float
    public var z: Float

    public init(w: Float, x: Float, y: Float, z: Float) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = WMRQuaternion(w: 1, x: 0, y: 0, z: 0)

    public var normSquared: Float {
        w * w + x * x + y * y + z * z
    }

    public var norm: Float {
        sqrt(normSquared)
    }

    public func normalized() -> WMRQuaternion {
        let n = norm
        guard n > 0 else { return .identity }
        return WMRQuaternion(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    public func conjugate() -> WMRQuaternion {
        WMRQuaternion(w: w, x: -x, y: -y, z: -z)
    }

    public static func * (lhs: WMRQuaternion, rhs: WMRQuaternion) -> WMRQuaternion {
        WMRQuaternion(
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z,
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w
        )
    }

    /// Converts to Euler angles in degrees (roll: X, pitch: Y, yaw: Z).
    public func toEulerDegrees() -> (roll: Float, pitch: Float, yaw: Float) {
        // Roll (x-axis rotation)
        let sinr_cosp = 2 * (w * x + y * z)
        let cosr_cosp = 1 - 2 * (x * x + y * y)
        let roll = atan2(sinr_cosp, cosr_cosp)

        // Pitch (y-axis rotation)
        let sinp = 2 * (w * y - z * x)
        let pitch: Float
        if abs(sinp) >= 1 {
            pitch = copysign(Float.pi / 2, sinp)
        } else {
            pitch = asin(sinp)
        }

        // Yaw (z-axis rotation)
        let siny_cosp = 2 * (w * z + x * y)
        let cosy_cosp = 1 - 2 * (y * y + z * z)
        let yaw = atan2(siny_cosp, cosy_cosp)

        let radToDeg: Float = 180.0 / Float.pi
        return (roll: roll * radToDeg, pitch: pitch * radToDeg, yaw: yaw * radToDeg)
    }
}
