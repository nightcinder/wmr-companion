import XCTest
@testable import WMRCompanionKit

final class WMRConfigDecoderTests: XCTestCase {
    func testDeobfuscate() {
        let key = Data(repeating: 0x5A, count: 1024)
        let plainText = "{\"CalibrationInformation\":{}}"
        let plainBytes = Array(plainText.utf8)

        // Prepend 2 bytes prefix, then XOR with key
        var obfuscated = Data([0x12, 0x34])
        for (i, b) in plainBytes.enumerated() {
            obfuscated.append(b ^ key[i % 1024])
        }
        // Add some trailing NULs
        obfuscated.append(contentsOf: [0x5A, 0x5A, 0x5A]) // 0x00 ^ 0x5A = 0x5A

        let result = deobfuscateConfig(blob: obfuscated, key: key)
        guard case .success(let decoded) = result else {
            XCTFail("Failed to de-obfuscate")
            return
        }

        XCTAssertEqual(decoded, plainText)
    }

    func testParseCalibrationJson() {
        let jsonString = """
        {
            "CalibrationInformation": {
                "InertialSensors": [
                    {
                        "SensorType": "Controller_Gyro",
                        "Rt": {
                            "Rotation": [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                            "Translation": [0.01, 0.02, 0.03]
                        },
                        "MixingMatrixTemperatureModel": [
                            {"Model": [1.0, 0.0, 0.0, 0.0]},
                            {"Model": [0.0, 0.0, 0.0, 0.0]},
                            {"Model": [0.0, 0.0, 0.0, 0.0]},
                            {"Model": [0.0, 0.0, 0.0, 0.0]},
                            {"Model": [1.0, 0.0, 0.0, 0.0]},
                            {"Model": [0.0, 0.0, 0.0, 0.0]},
                            {"Model": [0.0, 0.0, 0.0, 0.0]},
                            {"Model": [0.0, 0.0, 0.0, 0.0]},
                            {"Model": [1.0, 0.0, 0.0, 0.0]}
                        ],
                        "BiasTemperatureModel": {
                            "Model": [0.01, 0.0, 0.0, 0.0, -0.02, 0.0, 0.0, 0.0, 0.03]
                        },
                        "BiasUncertainty": [0.001, 0.001, 0.001],
                        "Noise": [0.0001, 0.0001, 0.0001]
                    }
                ]
            }
        }
        """

        let result = parseControllerCalibration(jsonString: jsonString)
        guard case .success(let cal) = result else {
            XCTFail("Failed to parse calibration JSON")
            return
        }

        guard let gyro = cal.sensor(for: .gyro) else {
            XCTFail("Missing gyro sensor")
            return
        }

        XCTAssertEqual(gyro.rotation.count, 9)
        XCTAssertEqual(gyro.translation, [0.01, 0.02, 0.03])
        XCTAssertEqual(gyro.mixMatrix, [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0])
        XCTAssertEqual(gyro.bias, [0.01, -0.02, 0.03])
    }
}
