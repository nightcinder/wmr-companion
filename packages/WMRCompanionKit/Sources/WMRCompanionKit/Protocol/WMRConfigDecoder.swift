import Foundation

public enum ConfigDecodeError: Error, Equatable, Sendable {
    case invalidKeySize
    case blockTooShort
    case notUtf8
    case jsonParseError(String)
}

public enum InertialSensorType: String, Sendable {
    case gyro
    case accelerometer
    case magnetometer
    case unknown
}

public struct InertialSensorCalibration: Sendable {
    public let type: InertialSensorType
    public let typeName: String
    public let rotation: [Float]         // 9 floats (3x3 row-major)
    public let translation: [Float]      // 3 floats
    public let mixMatrix: [Float]        // 9 floats (3x3 row-major)
    public let bias: [Float]             // 3 floats
    public let biasUncertainty: [Float]  // 3 floats
    public let noise: [Float]            // 3 floats

    public init(
        type: InertialSensorType,
        typeName: String,
        rotation: [Float],
        translation: [Float],
        mixMatrix: [Float],
        bias: [Float],
        biasUncertainty: [Float],
        noise: [Float]
    ) {
        self.type = type
        self.typeName = typeName
        self.rotation = rotation
        self.translation = translation
        self.mixMatrix = mixMatrix
        self.bias = bias
        self.biasUncertainty = biasUncertainty
        self.noise = noise
    }
}

public struct ControllerCalibration: Sendable {
    public let sensors: [InertialSensorCalibration]

    public init(sensors: [InertialSensorCalibration]) {
        self.sensors = sensors
    }

    public func sensor(for type: InertialSensorType) -> InertialSensorCalibration? {
        return sensors.first { $0.type == type }
    }
}

/// De-obfuscates the controller configuration block (skips 2 prefix bytes, XORs with Monado key, trims NULs).
public func deobfuscateConfig(blob: Data, key: Data) -> Result<String, ConfigDecodeError> {
    guard key.count == WMRConstants.configKeySize else {
        return .failure(.invalidKeySize)
    }
    guard blob.count > WMRConstants.configSkipBytes else {
        return .failure(.blockTooShort)
    }

    let payloadLen = blob.count - WMRConstants.configSkipBytes
    var out = [UInt8](repeating: 0, count: payloadLen)

    for i in 0..<payloadLen {
        out[i] = blob[WMRConstants.configSkipBytes + i] ^ key[i % WMRConstants.configKeySize]
    }

    var validLen = payloadLen
    while validLen > 0 && out[validLen - 1] == 0 {
        validLen -= 1
    }

    guard let text = String(bytes: out[0..<validLen], encoding: .utf8) else {
        return .failure(.notUtf8)
    }
    return .success(text)
}

/// Parses the de-obfuscated JSON string into ControllerCalibration.
public func parseControllerCalibration(jsonString: String) -> Result<ControllerCalibration, ConfigDecodeError> {
    guard let data = jsonString.data(using: .utf8) else {
        return .failure(.notUtf8)
    }

    do {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.jsonParseError("Root is not a JSON dictionary"))
        }

        guard let calInfo = root["CalibrationInformation"] as? [String: Any],
              let inertialSensors = calInfo["InertialSensors"] as? [[String: Any]] else {
            return .failure(.jsonParseError("Missing CalibrationInformation.InertialSensors"))
        }

        var sensors: [InertialSensorCalibration] = []

        for sensorDict in inertialSensors {
            guard let sensorTypeStr = sensorDict["SensorType"] as? String else { continue }

            let type: InertialSensorType
            if sensorTypeStr.hasSuffix("_Gyro") {
                type = .gyro
            } else if sensorTypeStr.hasSuffix("_Accelerometer") {
                type = .accelerometer
            } else if sensorTypeStr.hasSuffix("_Magnetometer") {
                type = .magnetometer
            } else {
                type = .unknown
            }

            // Rt pose
            var rotation = [Float](repeating: 0, count: 9)
            var translation = [Float](repeating: 0, count: 3)
            if let rt = sensorDict["Rt"] as? [String: Any] {
                if let rotArr = rt["Rotation"] as? [NSNumber], rotArr.count >= 9 {
                    rotation = rotArr.prefix(9).map { $0.floatValue }
                }
                if let transArr = rt["Translation"] as? [NSNumber], transArr.count >= 3 {
                    translation = transArr.prefix(3).map { $0.floatValue }
                }
            }

            // MixingMatrixTemperatureModel: take model[4*i] for each of 9 elements
            var mixMatrix = [Float](repeating: 0, count: 9)
            if let mixModels = sensorDict["MixingMatrixTemperatureModel"] as? [[String: Any]], mixModels.count >= 9 {
                for i in 0..<9 {
                    if let modelCoeffs = mixModels[i]["Model"] as? [NSNumber], !modelCoeffs.isEmpty {
                        mixMatrix[i] = modelCoeffs[0].floatValue
                    }
                }
            }

            // BiasTemperatureModel: take model[0], model[4], model[8]
            var bias = [Float](repeating: 0, count: 3)
            if let biasModel = sensorDict["BiasTemperatureModel"] as? [String: Any],
               let modelCoeffs = biasModel["Model"] as? [NSNumber] {
                if modelCoeffs.count > 0 { bias[0] = modelCoeffs[0].floatValue }
                if modelCoeffs.count > 4 { bias[1] = modelCoeffs[4].floatValue }
                if modelCoeffs.count > 8 { bias[2] = modelCoeffs[8].floatValue }
            }

            var biasUncertainty = [Float](repeating: 0, count: 3)
            if let bu = sensorDict["BiasUncertainty"] as? [NSNumber], bu.count >= 3 {
                biasUncertainty = bu.prefix(3).map { $0.floatValue }
            }

            var noise = [Float](repeating: 0, count: 3)
            if let n = sensorDict["Noise"] as? [NSNumber], n.count >= 3 {
                noise = n.prefix(3).map { $0.floatValue }
            }

            sensors.append(InertialSensorCalibration(
                type: type,
                typeName: sensorTypeStr,
                rotation: rotation,
                translation: translation,
                mixMatrix: mixMatrix,
                bias: bias,
                biasUncertainty: biasUncertainty,
                noise: noise
            ))
        }

        return .success(ControllerCalibration(sensors: sensors))
    } catch {
        return .failure(.jsonParseError(error.localizedDescription))
    }
}
