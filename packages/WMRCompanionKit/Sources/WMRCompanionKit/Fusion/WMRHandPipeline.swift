import Foundation

/// Axis mapping configuration to convert raw IMU sensor coordinates to app/view axes.
/// Default (from PROTOCOL.md and axis_mapping.dart):
/// View X = -sensor Y, View Y = +sensor X, View Z = +sensor Z.
public struct WMRAxisMapping: Sendable {
    public var source: [Int] // [viewX reads sensorIdx, viewY reads sensorIdx, viewZ reads sensorIdx]
    public var sign: [Float] // [+1 or -1 for each view axis]
    public var flip: [Bool]
    public var gyroFlip: [Bool]

    public init(
        source: [Int] = [1, 0, 2],       // default: X from Y, Y from X, Z from Z
        sign: [Float] = [-1.0, 1.0, 1.0], // default: -Y, +X, +Z
        flip: [Bool] = [false, false, false],
        gyroFlip: [Bool] = [false, false, false]
    ) {
        self.source = source
        self.sign = sign
        self.flip = flip
        self.gyroFlip = gyroFlip
    }

    public static let defaultMapping = WMRAxisMapping()

    public func mapGyro(sensor: WMRVector3) -> WMRVector3 {
        let vals = [sensor.x, sensor.y, sensor.z]
        var out = [Float](repeating: 0, count: 3)
        for i in 0..<3 {
            let srcVal = vals[source[i]]
            let s = sign[i] * (flip[i] ? -1.0 : 1.0) * (gyroFlip[i] ? -1.0 : 1.0)
            out[i] = s * srcVal
        }
        return WMRVector3(x: out[0], y: out[1], z: out[2])
    }

    public func mapAccel(sensor: WMRVector3) -> WMRVector3 {
        let vals = [sensor.x, sensor.y, sensor.z]
        var out = [Float](repeating: 0, count: 3)
        for i in 0..<3 {
            let srcVal = vals[source[i]]
            let s = sign[i] * (flip[i] ? -1.0 : 1.0)
            out[i] = s * srcVal
        }
        return WMRVector3(x: out[0], y: out[1], z: out[2])
    }
}

/// Applies Monado IMU calibration: calibrated = R^T * (M * raw + bias)
public struct WMRImuCalibration: Sendable {
    public let gyroMix: [Float]         // 9 floats
    public let gyroBias: [Float]        // 3 floats
    public let gyroRotationT: [Float]   // 9 floats (transpose of Rt.Rotation)

    public let accelMix: [Float]        // 9 floats
    public let accelBias: [Float]       // 3 floats
    public let accelRotationT: [Float]  // 9 floats (transpose of Rt.Rotation)

    public init?(calibration: ControllerCalibration) {
        guard let g = calibration.sensor(for: .gyro),
              let a = calibration.sensor(for: .accelerometer),
              g.mixMatrix.count == 9, g.bias.count >= 3, g.rotation.count == 9,
              a.mixMatrix.count == 9, a.bias.count >= 3, a.rotation.count == 9 else {
            return nil
        }

        func transpose3x3(_ m: [Float]) -> [Float] {
            return [
                m[0], m[3], m[6],
                m[1], m[4], m[7],
                m[2], m[5], m[8]
            ]
        }

        self.gyroMix = g.mixMatrix
        self.gyroBias = g.bias
        self.gyroRotationT = transpose3x3(g.rotation)

        self.accelMix = a.mixMatrix
        self.accelBias = a.bias
        self.accelRotationT = transpose3x3(a.rotation)
    }

    private func applySensor(raw: WMRVector3, mix: [Float], bias: [Float], rotT: [Float]) -> WMRVector3 {
        // M * raw + bias
        let mx = mix[0] * raw.x + mix[1] * raw.y + mix[2] * raw.z + bias[0]
        let my = mix[3] * raw.x + mix[4] * raw.y + mix[5] * raw.z + bias[1]
        let mz = mix[6] * raw.x + mix[7] * raw.y + mix[8] * raw.z + bias[2]

        // R^T * mixed
        let rx = rotT[0] * mx + rotT[1] * my + rotT[2] * mz
        let ry = rotT[3] * mx + rotT[4] * my + rotT[5] * mz
        let rz = rotT[6] * mx + rotT[7] * my + rotT[8] * mz

        return WMRVector3(x: rx, y: ry, z: rz)
    }

    public func calibrateGyro(_ raw: WMRVector3) -> WMRVector3 {
        applySensor(raw: raw, mix: gyroMix, bias: gyroBias, rotT: gyroRotationT)
    }

    public func calibrateAccel(_ raw: WMRVector3) -> WMRVector3 {
        applySensor(raw: raw, mix: accelMix, bias: accelBias, rotT: accelRotationT)
    }
}

/// Pipeline processing samples for a single controller hand.
public final class WMRHandPipeline: @unchecked Sendable {
    public let hand: WMRHand
    public var filter: WMROrientationFilterBase
    public var axisMapping: WMRAxisMapping
    public var applyCalibration: Bool = false
    public var imuCalibration: WMRImuCalibration?

    private var lastDeviceTicks: UInt32?
    private var lastRxTimeUs: UInt64?
    private var lastSequence: UInt32?

    public private(set) var sequenceGaps: Int = 0
    public private(set) var missingTicksTotal: UInt64 = 0
    public private(set) var recordsCount: UInt64 = 0
    public private(set) var latestState: WMRControllerState?

    public init(
        hand: WMRHand,
        filter: WMROrientationFilterBase? = nil,
        axisMapping: WMRAxisMapping = .defaultMapping
    ) {
        self.hand = hand
        self.filter = filter ?? WMRMadgwickFilter()
        self.axisMapping = axisMapping
    }

    public func reset() {
        lastDeviceTicks = nil
        lastRxTimeUs = nil
        lastSequence = nil
        sequenceGaps = 0
        missingTicksTotal = 0
        recordsCount = 0
        filter.reset()
        latestState = nil
    }

    /// Ingests one DecodedRecord (from FF12 or FF14 batch).
    public func push(record: DecodedRecord) -> WMRControllerState {
        recordsCount += 1

        // Check sequence gaps
        if let lastSeq = lastSequence {
            let delta = sequenceDelta(lastSeq, record.sequence)
            if delta > 1 {
                sequenceGaps += Int(delta - 1)
            }
        }
        lastSequence = record.sequence

        // Compute dt from 100ns sensor device ticks
        var dt: Float = 0.005 // default ~200Hz nominal
        if let lastTicks = lastDeviceTicks {
            let ticks = tickDelta(lastTicks, record.deviceTicks)
            let nominalTicksPerSample: UInt32 = 50000 // 5ms = 50,000 x 100ns
            if ticks > nominalTicksPerSample + (nominalTicksPerSample / 2) {
                let missed = (ticks - (nominalTicksPerSample / 2)) / nominalTicksPerSample
                missingTicksTotal += UInt64(missed)
            }
            let rawDt = Float(Double(ticks) * WMRConstants.tickSeconds)
            if rawDt > 0.0001 && rawDt <= filter.maxDt {
                dt = rawDt
            }
        }
        lastDeviceTicks = record.deviceTicks
        lastRxTimeUs = record.rxTimeUs

        var gyroVec = WMRVector3(x: record.gyro.x, y: record.gyro.y, z: record.gyro.z)
        var accelVec = WMRVector3(x: record.accel.x, y: record.accel.y, z: record.accel.z)

        // Apply Monado calibration if configured and record is not pre-calibrated by firmware
        if applyCalibration && !record.calibrated, let cal = imuCalibration {
            gyroVec = cal.calibrateGyro(gyroVec)
            accelVec = cal.calibrateAccel(accelVec)
        }

        // Apply axis mapping (sensor -> view)
        let mappedGyro = axisMapping.mapGyro(sensor: gyroVec)
        let mappedAccel = axisMapping.mapAccel(sensor: accelVec)

        // Step orientation filter
        filter.update(gyro: mappedGyro, accel: mappedAccel, dt: dt)

        let orientation = filter.orientation
        let euler = orientation.toEulerDegrees()

        let totalExpected = recordsCount + missingTicksTotal
        let lossPercent = totalExpected > 0 ? (Double(missingTicksTotal) / Double(totalExpected)) * 100.0 : 0.0

        let state = WMRControllerState(
            hand: hand,
            isConnected: true,
            sequence: record.sequence,
            rxTimeUs: record.rxTimeUs,
            deviceTicks: record.deviceTicks,
            buttons: record.buttons,
            stick: record.stick,
            trackpad: record.trackpad,
            trigger: record.trigger,
            battery: record.battery,
            temperatureRaw: record.temperatureRaw,
            gyro: (mappedGyro.x, mappedGyro.y, mappedGyro.z),
            accel: (mappedAccel.x, mappedAccel.y, mappedAccel.z),
            orientation: (orientation.w, orientation.x, orientation.y, orientation.z),
            euler: euler,
            packetRateHz: dt > 0 ? Double(1.0 / dt) : 200.0,
            lossPercent: lossPercent,
            sequenceGaps: sequenceGaps
        )
        self.latestState = state
        return state
    }
}
