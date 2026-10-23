import Foundation

/// Axis mapping configuration to convert raw IMU sensor coordinates to app/world axes.
public struct WMRAxisMapping: Sendable {
    public var flipX: Bool
    public var flipY: Bool
    public var flipZ: Bool

    public init(flipX: Bool = false, flipY: Bool = false, flipZ: Bool = false) {
        self.flipX = flipX
        self.flipY = flipY
        self.flipZ = flipZ
    }

    /// Default mapping: World X right = -sensor Y, World Y up = +sensor X, World Z back = +sensor Z
    public func map(x: Float, y: Float, z: Float) -> WMRVector3 {
        let mx = flipX ? -x : x
        let my = flipY ? -y : y
        let mz = flipZ ? -z : z
        return WMRVector3(x: mx, y: my, z: mz)
    }
}

/// Pipeline processing samples for a single controller hand.
public final class WMRHandPipeline: @unchecked Sendable {
    public let hand: WMRHand
    public var filter: WMROrientationFilterBase
    public var axisMapping: WMRAxisMapping
    public var applyCalibration: Bool = false
    public var calibration: InertialSensorCalibration?

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
        axisMapping: WMRAxisMapping = WMRAxisMapping()
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
        var dt: Float = 0.005 // default ~200Hz
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
        if applyCalibration && !record.calibrated, let cal = calibration {
            if cal.mixMatrix.count == 9 {
                let m = cal.mixMatrix
                let gx = m[0] * gyroVec.x + m[1] * gyroVec.y + m[2] * gyroVec.z + cal.bias[0]
                let gy = m[3] * gyroVec.x + m[4] * gyroVec.y + m[5] * gyroVec.z + cal.bias[1]
                let gz = m[6] * gyroVec.x + m[7] * gyroVec.y + m[8] * gyroVec.z + cal.bias[2]
                gyroVec = WMRVector3(x: gx, y: gy, z: gz)
            }
        }

        // Apply axis mapping
        let mappedGyro = axisMapping.map(x: gyroVec.x, y: gyroVec.y, z: gyroVec.z)
        let mappedAccel = axisMapping.map(x: accelVec.x, y: accelVec.y, z: accelVec.z)

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
