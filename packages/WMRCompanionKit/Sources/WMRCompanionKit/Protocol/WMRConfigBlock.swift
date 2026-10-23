import Foundation

public enum ConfigState: UInt8, CaseIterable, Sendable {
    case notRead = 0
    case reading = 1
    case ready = 2
    case failed = 3
}

public enum ConfigParseError: Error, Equatable, Sendable {
    case tooShort
    case unknownVersion
    case unknownState
    case badHand
}

public struct ConfigWindow: Equatable, Sendable {
    public let hand: WMRHand
    public let state: ConfigState
    public let totalLen: UInt32
    public let offset: UInt32
    public let crc32: UInt32
    public let data: Data

    public init(
        hand: WMRHand,
        state: ConfigState,
        totalLen: UInt32,
        offset: UInt32,
        crc32: UInt32,
        data: Data
    ) {
        self.hand = hand
        self.state = state
        self.totalLen = totalLen
        self.offset = offset
        self.crc32 = crc32
        self.data = data
    }
}

/// Computes IEEE 802.3 reflected CRC-32 (polynomial 0xEDB88320).
public func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            if (crc & 1) != 0 {
                crc = (crc >> 1) ^ 0xEDB88320
            } else {
                crc = crc >> 1
            }
        }
    }
    return ~crc
}

/// Encodes a 5-byte cursor write for FF13.
public func encodeConfigCursor(hand: WMRHand, offset: UInt32) -> Data {
    var out = Data(count: WMRConstants.configCursorSize)
    out[0] = hand.rawValue
    let offLE = offset.littleEndian
    withUnsafeBytes(of: offLE) { out.replaceSubrange(1..<5, with: $0) }
    return out
}

/// Parses a 16-byte header + data window from FF13.
public func parseConfigWindow(_ data: Data) -> Result<ConfigWindow, ConfigParseError> {
    guard data.count >= WMRConstants.configHeaderSize else {
        return .failure(.tooShort)
    }
    guard data[0] == WMRConstants.configVersion else {
        return .failure(.unknownVersion)
    }
    let handVal = data[1]
    guard handVal < 2, let hand = WMRHand(rawValue: handVal) else {
        return .failure(.badHand)
    }
    guard let state = ConfigState(rawValue: data[2]) else {
        return .failure(.unknownState)
    }

    let totalLen = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
    let offset = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian }
    let crcVal = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian }
    let payload = data.subdata(in: WMRConstants.configHeaderSize..<data.count)

    let window = ConfigWindow(
        hand: hand,
        state: state,
        totalLen: totalLen,
        offset: offset,
        crc32: crcVal,
        data: payload
    )
    return .success(window)
}

/// Encodes a ConfigWindow (for tests/mock bridge).
public func encodeConfigWindow(
    hand: WMRHand,
    state: ConfigState,
    blob: Data? = nil,
    offset: Int = 0
) -> Data {
    let isReady = (state == .ready && blob != nil)
    let totalLen = isReady ? UInt32(blob!.count) : 0
    let crcVal = isReady ? crc32(blob!) : 0

    var payloadCount = 0
    if isReady, let b = blob, offset < b.count {
        payloadCount = min(b.count - offset, WMRConstants.configWindowMax)
    }

    var out = Data(count: WMRConstants.configHeaderSize + payloadCount)
    out[0] = WMRConstants.configVersion
    out[1] = hand.rawValue
    out[2] = state.rawValue

    let totalLE = totalLen.littleEndian
    withUnsafeBytes(of: totalLE) { out.replaceSubrange(4..<8, with: $0) }

    let offLE = UInt32(offset).littleEndian
    withUnsafeBytes(of: offLE) { out.replaceSubrange(8..<12, with: $0) }

    let crcLE = crcVal.littleEndian
    withUnsafeBytes(of: crcLE) { out.replaceSubrange(12..<16, with: $0) }

    if payloadCount > 0, let b = blob {
        let chunk = b.subdata(in: offset..<(offset + payloadCount))
        out.replaceSubrange(WMRConstants.configHeaderSize..<out.count, with: chunk)
    }
    return out
}
