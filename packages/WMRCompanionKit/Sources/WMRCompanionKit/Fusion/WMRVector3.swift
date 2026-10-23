import Foundation

/// A 3D single-precision float vector.
public struct WMRVector3: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = WMRVector3(x: 0, y: 0, z: 0)

    public var lengthSquared: Float {
        x * x + y * y + z * z
    }

    public var length: Float {
        sqrt(lengthSquared)
    }

    public func normalized() -> WMRVector3 {
        let len = length
        guard len > 0 else { return .zero }
        return WMRVector3(x: x / len, y: y / len, z: z / len)
    }

    public func dot(_ other: WMRVector3) -> Float {
        x * other.x + y * other.y + z * other.z
    }

    public func cross(_ other: WMRVector3) -> WMRVector3 {
        WMRVector3(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    public static func + (lhs: WMRVector3, rhs: WMRVector3) -> WMRVector3 {
        WMRVector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: WMRVector3, rhs: WMRVector3) -> WMRVector3 {
        WMRVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    public static func * (lhs: WMRVector3, rhs: Float) -> WMRVector3 {
        WMRVector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }
}
