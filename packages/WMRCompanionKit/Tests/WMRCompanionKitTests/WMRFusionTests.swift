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

    func testMadgwickConvergence() {
        let filter = WMRMadgwickFilter(beta: 0.1)
        // Upright at rest: accel is +10 on up axis (world Z)
        let accel = WMRVector3(x: 0, y: 0, z: 9.81)
        let gyro = WMRVector3.zero

        // Step 100 times at 200Hz (dt = 0.005s)
        for _ in 0..<100 {
            filter.update(gyro: gyro, accel: accel, dt: 0.005)
        }

        let q = filter.orientation
        XCTAssertTrue(q.norm > 0.99 && q.norm < 1.01)
        let euler = q.toEulerDegrees()
        // Pitch and roll should remain near 0 when upright
        XCTAssertLessThan(abs(euler.pitch), 5.0)
        XCTAssertLessThan(abs(euler.roll), 5.0)
    }

    func testMahonyConvergence() {
        let filter = WMRMahonyFilter(kp: 1.0, ki: 0.05)
        let accel = WMRVector3(x: 0, y: 0, z: 9.81)
        let gyro = WMRVector3.zero

        for _ in 0..<100 {
            filter.update(gyro: gyro, accel: accel, dt: 0.005)
        }

        let q = filter.orientation
        XCTAssertTrue(q.norm > 0.99 && q.norm < 1.01)
    }
}
