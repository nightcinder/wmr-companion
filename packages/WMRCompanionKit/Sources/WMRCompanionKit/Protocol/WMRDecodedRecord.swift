import Foundation

public enum DecodedParseError: Error, Equatable, Sendable {
    case wrongLength
    case unknownVersion
    case badHand
}

/// One decoded 56-byte sample from the bridge (FF12).
public struct DecodedRecord: Equatable, Sendable {
    public let hand: WMRHand
    public let flags: UInt8
    public let buttons: WMRButtonState
    public let sequence: UInt32
    public let rxTimeUs: UInt64
    public let deviceTicks: UInt32
    public let gyro: (x: Float, y: Float, z: Float)
    public let accel: (x: Float, y: Float, z: Float)
    public let temperatureRaw: Int16
    public let stick: (x: Int16, y: Int16)
    public let trackpad: (x: Int16, y: Int16)
    public let trigger: UInt8
    public let battery: UInt8

    public var calibrated: Bool {
        (flags & WMRConstants.decodedFlagCalibrated) != 0
    }

    public init(
        hand: WMRHand,
        flags: UInt8 = 0,
        buttons: WMRButtonState = [],
        sequence: UInt32,
        rxTimeUs: UInt64,
        deviceTicks: UInt32,
        gyro: (x: Float, y: Float, z: Float),
        accel: (x: Float, y: Float, z: Float),
        temperatureRaw: Int16 = 0,
        stick: (x: Int16, y: Int16) = (0, 0),
        trackpad: (x: Int16, y: Int16) = (0, 0),
        trigger: UInt8 = 0,
        battery: UInt8 = 0
    ) {
        self.hand = hand
        self.flags = flags
        self.buttons = buttons
        self.sequence = sequence
        self.rxTimeUs = rxTimeUs
        self.deviceTicks = deviceTicks
        self.gyro = gyro
        self.accel = accel
        self.temperatureRaw = temperatureRaw
        self.stick = stick
        self.trackpad = trackpad
        self.trigger = trigger
        self.battery = battery
    }

    public static func == (lhs: DecodedRecord, rhs: DecodedRecord) -> Bool {
        return lhs.hand == rhs.hand &&
            lhs.flags == rhs.flags &&
            lhs.buttons == rhs.buttons &&
            lhs.sequence == rhs.sequence &&
            lhs.rxTimeUs == rhs.rxTimeUs &&
            lhs.deviceTicks == rhs.deviceTicks &&
            lhs.gyro.x == rhs.gyro.x && lhs.gyro.y == rhs.gyro.y && lhs.gyro.z == rhs.gyro.z &&
            lhs.accel.x == rhs.accel.x && lhs.accel.y == rhs.accel.y && lhs.accel.z == rhs.accel.z &&
            lhs.temperatureRaw == rhs.temperatureRaw &&
            lhs.stick.x == rhs.stick.x && lhs.stick.y == rhs.stick.y &&
            lhs.trackpad.x == rhs.trackpad.x && lhs.trackpad.y == rhs.trackpad.y &&
            lhs.trigger == rhs.trigger &&
            lhs.battery == rhs.battery
    }
}

/// Unsigned delta `b - a` modulo 2^32 across wraps.
public func tickDelta(_ a: UInt32, _ b: UInt32) -> UInt32 {
    let diff = (Int64(b) - Int64(a)) & 0xFFFFFFFF
    return UInt32(diff)
}

/// Parses a 56-byte FF12 record value matching `wmr_decoded_unpack`.
public func parseDecodedRecord(_ data: Data) -> Result<DecodedRecord, DecodedParseError> {
    guard data.count == WMRConstants.decodedRecordSize else {
        return .failure(.wrongLength)
    }
    guard data[0] == WMRConstants.decodedRecordVersion else {
        return .failure(.unknownVersion)
    }
    let handVal = data[1]
    guard handVal < 2, let hand = WMRHand(rawValue: handVal) else {
        return .failure(.badHand)
    }

    let flags = data[2]
    let buttons = WMRButtonState(rawValue: data[3])

    let sequence = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
    let rxTimeUs = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian }
    let deviceTicks = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self).littleEndian }

    func loadFloat(at offset: Int) -> Float {
        let u32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
        return Float(bitPattern: u32)
    }

    let gyro = (
        x: loadFloat(at: 20),
        y: loadFloat(at: 24),
        z: loadFloat(at: 28)
    )

    let accel = (
        x: loadFloat(at: 32),
        y: loadFloat(at: 36),
        z: loadFloat(at: 40)
    )

    let tempRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 44, as: Int16.self).littleEndian }
    let stickX = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 46, as: Int16.self).littleEndian }
    let stickY = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 48, as: Int16.self).littleEndian }
    let padX = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 50, as: Int16.self).littleEndian }
    let padY = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 52, as: Int16.self).littleEndian }
    let trigger = data[54]
    let battery = data[55]

    let record = DecodedRecord(
        hand: hand,
        flags: flags,
        buttons: buttons,
        sequence: sequence,
        rxTimeUs: rxTimeUs,
        deviceTicks: deviceTicks,
        gyro: gyro,
        accel: accel,
        temperatureRaw: tempRaw,
        stick: (stickX, stickY),
        trackpad: (padX, padY),
        trigger: trigger,
        battery: battery
    )
    return .success(record)
}

/// Serializes a DecodedRecord into 56 bytes matching `wmr_decoded_pack`.
public func encodeDecodedRecord(_ r: DecodedRecord) -> Data {
    var out = Data(count: WMRConstants.decodedRecordSize)
    out[0] = WMRConstants.decodedRecordVersion
    out[1] = r.hand.rawValue
    out[2] = r.flags
    out[3] = r.buttons.rawValue

    let seqLE = r.sequence.littleEndian
    withUnsafeBytes(of: seqLE) { out.replaceSubrange(4..<8, with: $0) }

    let rxLE = r.rxTimeUs.littleEndian
    withUnsafeBytes(of: rxLE) { out.replaceSubrange(8..<16, with: $0) }

    let ticksLE = r.deviceTicks.littleEndian
    withUnsafeBytes(of: ticksLE) { out.replaceSubrange(16..<20, with: $0) }

    func putFloat(_ val: Float, at offset: Int) {
        let u32 = val.bitPattern.littleEndian
        withUnsafeBytes(of: u32) { out.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    putFloat(r.gyro.x, at: 20)
    putFloat(r.gyro.y, at: 24)
    putFloat(r.gyro.z, at: 28)

    putFloat(r.accel.x, at: 32)
    putFloat(r.accel.y, at: 36)
    putFloat(r.accel.z, at: 40)

    let tempLE = r.temperatureRaw.littleEndian
    withUnsafeBytes(of: tempLE) { out.replaceSubrange(44..<46, with: $0) }

    let stickXLE = r.stick.x.littleEndian
    withUnsafeBytes(of: stickXLE) { out.replaceSubrange(46..<48, with: $0) }

    let stickYLE = r.stick.y.littleEndian
    withUnsafeBytes(of: stickYLE) { out.replaceSubrange(48..<50, with: $0) }

    let padXLE = r.trackpad.x.littleEndian
    withUnsafeBytes(of: padXLE) { out.replaceSubrange(50..<52, with: $0) }

    let padYLE = r.trackpad.y.littleEndian
    withUnsafeBytes(of: padYLE) { out.replaceSubrange(52..<54, with: $0) }

    out[54] = r.trigger
    out[55] = r.battery

    return out
}
