import Foundation

/// Base class for 3DoF orientation filters (gyro + accel, no magnetometer).
open class WMROrientationFilterBase: @unchecked Sendable {
    public let maxDt: Float
    public let minAccelNorm: Float

    private var _w: Float = 1
    private var _x: Float = 0
    private var _y: Float = 0
    private var _z: Float = 0
    private var _initialized: Bool = false
    private var _skipped: Int = 0

    public init(maxDt: Float = 0.1, minAccelNorm: Float = 0.1) {
        self.maxDt = maxDt
        self.minAccelNorm = minAccelNorm
    }

    public var orientation: WMRQuaternion {
        WMRQuaternion(w: _w, x: _x, y: _y, z: _z)
    }

    public var skippedUpdates: Int { _skipped }
    public var isInitialized: Bool { _initialized }

    public func reset(to orientation: WMRQuaternion? = nil) {
        _skipped = 0
        onReset()
        if let q = orientation, q.norm > 1e-6 {
            let n = q.normalized()
            setState(w: n.w, x: n.x, y: n.y, z: n.z)
            _initialized = true
        } else {
            setState(w: 1, x: 0, y: 0, z: 0)
            _initialized = false
        }
    }

    public func resetYaw() {
        let euler = orientation.toEulerDegrees()
        let degToRad = Float.pi / 180.0
        let yawRad = euler.yaw * degToRad
        let halfYaw = -yawRad * 0.5
        let unyaw = WMRQuaternion(w: cos(halfYaw), x: 0, y: 0, z: sin(halfYaw))
        let newQ = (unyaw * orientation).normalized()
        setState(w: newQ.w, x: newQ.x, y: newQ.y, z: newQ.z)
    }

    public func update(gyro: WMRVector3, accel: WMRVector3, dt: Float) {
        guard !gyro.x.isNaN, !gyro.y.isNaN, !gyro.z.isNaN,
              !accel.x.isNaN, !accel.y.isNaN, !accel.z.isNaN else {
            _skipped += 1
            return
        }

        let accelUsable = accel.length >= minAccelNorm

        if !_initialized {
            if accelUsable {
                let initQ = Self.tiltFromAccel(accel)
                setState(w: initQ.w, x: initQ.x, y: initQ.y, z: initQ.z)
                _initialized = true
            }
            return
        }

        guard !dt.isNaN, dt > 0, dt <= maxDt else {
            _skipped += 1
            return
        }

        step(gyro: gyro, accelUnit: accelUsable ? accel.normalized() : nil, dt: dt)

        let q = WMRQuaternion(w: _w, x: _x, y: _y, z: _z)
        if q.norm > 1e-6 {
            let n = q.normalized()
            setState(w: n.w, x: n.x, y: n.y, z: n.z)
        } else {
            setState(w: 1, x: 0, y: 0, z: 0)
        }
    }

    open func step(gyro: WMRVector3, accelUnit: WMRVector3?, dt: Float) {
        fatalError("Must be implemented by subclass")
    }

    open func onReset() {}

    public var w: Float { _w }
    public var x: Float { _x }
    public var y: Float { _y }
    public var z: Float { _z }

    public func setState(w: Float, x: Float, y: Float, z: Float) {
        self._w = w
        self._x = x
        self._y = y
        self._z = z
    }

    private static func tiltFromAccel(_ accel: WMRVector3) -> WMRQuaternion {
        let a = accel.normalized()
        if a.z < -0.999999 {
            return WMRQuaternion(w: 0, x: 1, y: 0, z: 0) // upside down
        }
        return WMRQuaternion(w: 1 + a.z, x: a.y, y: -a.x, z: 0).normalized()
    }
}

/// First-order quaternion integration of angular velocity.
public func integrateRate(w: Float, x: Float, y: Float, z: Float, g: WMRVector3, dt: Float) -> WMRQuaternion {
    let h = 0.5 * dt
    return WMRQuaternion(
        w: w + h * (-x * g.x - y * g.y - z * g.z),
        x: x + h * (w * g.x + y * g.z - z * g.y),
        y: y + h * (w * g.y - x * g.z + z * g.x),
        z: z + h * (w * g.z + x * g.y - y * g.x)
    )
}

/// Madgwick gradient-descent filter (6-axis gyro + accel).
public final class WMRMadgwickFilter: WMROrientationFilterBase {
    public var beta: Float

    public init(beta: Float = 0.05, maxDt: Float = 0.1, minAccelNorm: Float = 0.1) {
        self.beta = beta
        super.init(maxDt: maxDt, minAccelNorm: minAccelNorm)
    }

    public override func step(gyro: WMRVector3, accelUnit: WMRVector3?, dt: Float) {
        let q0 = w, q1 = x, q2 = y, q3 = z

        // Rate of change from gyro
        var d0 = 0.5 * (-q1 * gyro.x - q2 * gyro.y - q3 * gyro.z)
        var d1 = 0.5 * (q0 * gyro.x + q2 * gyro.z - q3 * gyro.y)
        var d2 = 0.5 * (q0 * gyro.y - q1 * gyro.z + q3 * gyro.x)
        var d3 = 0.5 * (q0 * gyro.z + q1 * gyro.y - q2 * gyro.x)

        if let a = accelUnit {
            let s0 = 4 * q0 * q2 * q2 + 2 * q2 * a.x + 4 * q0 * q1 * q1 - 2 * q1 * a.y
            let s1 = 4 * q1 * q3 * q3 - 2 * q3 * a.x + 4 * q0 * q0 * q1 - 2 * q0 * a.y - 4 * q1 + 8 * q1 * q1 * q1 + 8 * q1 * q2 * q2 + 4 * q1 * a.z
            let s2 = 4 * q0 * q0 * q2 + 2 * q0 * a.x + 4 * q2 * q3 * q3 - 2 * q3 * a.y - 4 * q2 + 8 * q2 * q1 * q1 + 8 * q2 * q2 * q2 + 4 * q2 * a.z
            let s3 = 4 * q1 * q1 * q3 - 2 * q1 * a.x + 4 * q2 * q2 * q3 - 2 * q2 * a.y

            let normS = sqrt(s0 * s0 + s1 * s1 + s2 * s2 + s3 * s3)
            if normS > 1e-12 {
                d0 -= beta * (s0 / normS)
                d1 -= beta * (s1 / normS)
                d2 -= beta * (s2 / normS)
                d3 -= beta * (s3 / normS)
            }
        }

        setState(w: q0 + d0 * dt, x: q1 + d1 * dt, y: q2 + d2 * dt, z: q3 + d3 * dt)
    }
}
