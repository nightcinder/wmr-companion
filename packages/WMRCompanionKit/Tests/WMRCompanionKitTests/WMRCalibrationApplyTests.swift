import XCTest
@testable import WMRCompanionKit

final class WMRCalibrationApplyTests: XCTestCase {
    func testCalibrationArithmetic() {
        let cal = ControllerCalibration(sensors: [
            InertialSensorCalibration(
                type: .gyro,
                typeName: "Controller_Gyro",
                rotation: [
                    0, 1, 0, // R = [[0, 1, 0], [1, 0, 0], [0, 0, 1]] (R^T is same)
                    1, 0, 0,
                    0, 0, 1
                ],
                translation: [0, 0, 0],
                mixMatrix: [
                    2, 0, 0, // M is 2x on X, 1x on Y, 1x on Z
                    0, 1, 0,
                    0, 0, 1
                ],
                bias: [0.1, -0.2, 0.0],
                biasUncertainty: [0, 0, 0],
                noise: [0, 0, 0]
            ),
            InertialSensorCalibration(
                type: .accelerometer,
                typeName: "Controller_Accelerometer",
                rotation: [
                    1, 0, 0,
                    0, 1, 0,
                    0, 0, 1
                ],
                translation: [0, 0, 0],
                mixMatrix: [
                    1, 0, 0,
                    0, 1, 0,
                    0, 0, 1
                ],
                bias: [0, 0, 0],
                biasUncertainty: [0, 0, 0],
                noise: [0, 0, 0]
            )
        ])

        guard let imuCal = WMRImuCalibration(calibration: cal) else {
            XCTFail("Failed to build ImuCalibration")
            return
        }

        // Raw gyro: (1.0, 2.0, 3.0)
        // M * raw + bias = (2*1 + 0.1, 1*2 - 0.2, 1*3 + 0) = (2.1, 1.8, 3.0)
        // R^T * mixed = (1.8, 2.1, 3.0)
        let calibratedGyro = imuCal.calibrateGyro(WMRVector3(x: 1.0, y: 2.0, z: 3.0))
        XCTAssertEqual(calibratedGyro.x, 1.8, accuracy: 1e-5)
        XCTAssertEqual(calibratedGyro.y, 2.1, accuracy: 1e-5)
        XCTAssertEqual(calibratedGyro.z, 3.0, accuracy: 1e-5)

        // Raw accel with identity: stays same
        let calibratedAccel = imuCal.calibrateAccel(WMRVector3(x: 0, y: 0, z: 9.81))
        XCTAssertEqual(calibratedAccel.x, 0, accuracy: 1e-5)
        XCTAssertEqual(calibratedAccel.y, 0, accuracy: 1e-5)
        XCTAssertEqual(calibratedAccel.z, 9.81, accuracy: 1e-5)
    }
}
