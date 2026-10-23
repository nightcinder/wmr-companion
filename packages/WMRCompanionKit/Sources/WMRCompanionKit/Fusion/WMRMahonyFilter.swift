import Foundation

/// Mahony complementary filter (6-axis gyro + accel with integral bias tracking).
public final class WMRMahonyFilter: WMROrientationFilterBase {
    public var kp: Float
    public var ki: Float
    public let maxBias: Float

    private var integral: WMRVector3 = .zero

    public init(kp: Float = 1.0, ki: Float = 0.05, maxBias: Float = 0.5, maxDt: Float = 0.1, minAccelNorm: Float = 0.1) {
        self.kp = kp
        self.ki = ki
        self.maxBias = maxBias
        super.init(maxDt: maxDt, minAccelNorm: minAccelNorm)
    }

    public var gyroBiasEstimate: WMRVector3 {
        WMRVector3(x: -integral.x, y: -integral.y, z: -integral.z)
    }

    public override func onReset() {
        integral = .zero
    }

    public override func step(gyro: WMRVector3, accelUnit: WMRVector3?, dt: Float) {
        if let a = accelUnit {
            let v = WMRVector3(
                x: 2 * (x * z - w * y),
                y: 2 * (w * x + y * z),
                z: w * w - x * x - y * y + z * z
            )
            let e = a.cross(v)

            if ki > 0 {
                let ix = min(max(integral.x + ki * e.x * dt, -maxBias), maxBias)
                let iy = min(max(integral.y + ki * e.y * dt, -maxBias), maxBias)
                let iz = min(max(integral.z + ki * e.z * dt, -maxBias), maxBias)
                integral = WMRVector3(x: ix, y: iy, z: iz)
            }

            let correctedRate = gyro + (e * kp) + integral
            let q = integrateRate(w: w, x: x, y: y, z: z, g: correctedRate, dt: dt)
            setState(w: q.w, x: q.x, y: q.y, z: q.z)
        } else {
            let q = integrateRate(w: w, x: x, y: y, z: z, g: gyro + integral, dt: dt)
            setState(w: q.w, x: q.x, y: q.y, z: q.z)
        }
    }
}
