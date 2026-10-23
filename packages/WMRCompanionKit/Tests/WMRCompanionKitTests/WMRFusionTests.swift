import XCTest
@testable import WMRCompanionKit

final class WMRFusionTests: XCTestCase {
    func testVector3() {
        let v1 = WMRVector3(x: 1, y: 2, z: 3)
        let v2 = WMRVector3(x: 4, y: 5, z: 6)
        XCTAssertEqual(v1 + v2, WMRVector3(x: 5, y: 7, z: 9))
        XCTAssertEqual(v1.dot(v2), 32)
        let cross = v1.cross(v2)
        XCTAssertEqual(cross, WMRVector3(x: -3, y: 6, z: -3))
    }

    func testQuaternion() {
        let q1 = WMRQuaternion.identity
        let q2 = WMRQuaternion(w: 0, x: 1, y: 0, z: 0)
        XCTAssertEqual((q1 * q2).normalized(), q2)
        XCTAssertEqual(q2.conjugate(), WMRQuaternion(w: 0, x: -1, y: 0, z: 0))
    }

    func testMadgwickConvergenceFromTiltedOrientation() {
        let filter = WMRMadgwickFilter(beta: 0.5)

        // Seed with a 45-degree roll tilt (w = cos(pi/8) ~ 0.9239, x = sin(pi/8) ~ 0.3827)
        let tiltedQ = WMRQuaternion(w: 0.9238795, x: 0.3826834, y: 0, z: 0)
        filter.reset(to: tiltedQ)

        let initialEuler = filter.orientation.toEulerDegrees()
        XCTAssertGreaterThan(abs(initialEuler.roll), 40.0)

        // Upright at rest: accel is +9.81 on up axis (world Z)
        let accel = WMRVector3(x: 0, y: 0, z: 9.81)
        let gyro = WMRVector3.zero

        // Step 300 times at 200Hz (dt = 0.005s) to allow convergence
        for _ in 0..<300 {
            filter.update(gyro: gyro, accel: accel, dt: 0.005)
        }

        let q = filter.orientation
        XCTAssertTrue(q.norm > 0.99 && q.norm < 1.01)
        let euler = q.toEulerDegrees()
        // Pitch and roll should converge to near 0 (< 3 degrees)
        XCTAssertLessThan(abs(euler.pitch), 3.0)
        XCTAssertLessThan(abs(euler.roll), 3.0)
    }

    func testMahonyConvergenceFromTiltedOrientation() {
        let filter = WMRMahonyFilter(kp: 2.0, ki: 0.05)

        // Seed with a 45-degree tilt
        let tiltedQ = WMRQuaternion(w: 0.9238795, x: 0.3826834, y: 0, z: 0)
        filter.reset(to: tiltedQ)

        let accel = WMRVector3(x: 0, y: 0, z: 9.81)
        let gyro = WMRVector3.zero

        for _ in 0..<300 {
            filter.update(gyro: gyro, accel: accel, dt: 0.005)
        }

        let q = filter.orientation
        XCTAssertTrue(q.norm > 0.99 && q.norm < 1.01)
        let euler = q.toEulerDegrees()
        XCTAssertLessThan(abs(euler.pitch), 3.0)
        XCTAssertLessThan(abs(euler.roll), 3.0)
    }

    func testAxisMapping() {
        let mapping = WMRAxisMapping.defaultMapping
        // Sensor: X=1, Y=2, Z=3
        // View: X = -Y = -2, Y = +X = 1, Z = +Z = 3
        let mapped = mapping.mapGyro(sensor: WMRVector3(x: 1, y: 2, z: 3))
        XCTAssertEqual(mapped.x, -2)
        XCTAssertEqual(mapped.y, 1)
        XCTAssertEqual(mapped.z, 3)
    }
}
