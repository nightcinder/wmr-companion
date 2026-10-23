import Foundation

public enum EchoParseError: Error, Equatable, Sendable {
    case wrongLength
    case unknownVersion
}

/// One echo answer from the bridge's FF15 characteristic.
public struct EchoAnswer: Equatable, Sendable {
    public let pingId: UInt16
    public let rxTimeUs: UInt64
    public let turnaroundUs: UInt32
    public let queueDepth: UInt16

    public init(pingId: UInt16, rxTimeUs: UInt64, turnaroundUs: UInt32, queueDepth: UInt16) {
        self.pingId = pingId
        self.rxTimeUs = rxTimeUs
        self.turnaroundUs = turnaroundUs
        self.queueDepth = queueDepth
    }
}

/// Encodes an FF15 echo request ping (4 bytes).
public func encodeEchoRequest(pingId: UInt16) -> Data {
    var out = Data(count: WMRConstants.echoRequestSize)
    out[0] = WMRConstants.echoVersion
    out[1] = 0
    let idLE = pingId.littleEndian
    withUnsafeBytes(of: idLE) { out.replaceSubrange(2..<4, with: $0) }
    return out
}

/// Parses an FF15 echo answer notification (20 bytes).
public func parseEchoAnswer(_ data: Data) -> Result<EchoAnswer, EchoParseError> {
    guard data.count == WMRConstants.echoAnswerSize else {
        return .failure(.wrongLength)
    }
    guard data[0] == WMRConstants.echoVersion else {
        return .failure(.unknownVersion)
    }

    let pingId = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self).littleEndian }
    let rxTimeUs = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self).littleEndian }
    let turnaroundUs = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian }
    let queueDepth = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt16.self).littleEndian }

    let answer = EchoAnswer(
        pingId: pingId,
        rxTimeUs: rxTimeUs,
        turnaroundUs: turnaroundUs,
        queueDepth: queueDepth
    )
    return .success(answer)
}

/// Encodes an EchoAnswer into 20 bytes (for testing/mocking).
public func encodeEchoAnswer(_ answer: EchoAnswer) -> Data {
    var out = Data(count: WMRConstants.echoAnswerSize)
    out[0] = WMRConstants.echoVersion
    out[1] = 0

    let idLE = answer.pingId.littleEndian
    withUnsafeBytes(of: idLE) { out.replaceSubrange(2..<4, with: $0) }

    let rxLE = answer.rxTimeUs.littleEndian
    withUnsafeBytes(of: rxLE) { out.replaceSubrange(4..<12, with: $0) }

    let turnLE = answer.turnaroundUs.littleEndian
    withUnsafeBytes(of: turnLE) { out.replaceSubrange(12..<16, with: $0) }

    let qLE = answer.queueDepth.littleEndian
    withUnsafeBytes(of: qLE) { out.replaceSubrange(16..<18, with: $0) }

    return out
}
