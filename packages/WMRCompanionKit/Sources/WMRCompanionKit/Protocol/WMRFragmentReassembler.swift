import Foundation

/// Represents one complete, unfragmented controller HID input report.
public struct WmrFrame: Equatable, Sendable {
    public let hand: WMRHand
    public let sequence: UInt32
    public let data: Data

    public init(hand: WMRHand, sequence: UInt32, data: Data) {
        self.hand = hand
        self.sequence = sequence
        self.data = data
    }

    public var count: Int { data.count }
}

/// Signed difference `b - a` modulo 2^32. +1 means consecutive.
public func sequenceDelta(_ a: UInt32, _ b: UInt32) -> Int32 {
    let diff = (Int64(b) - Int64(a)) & 0xFFFFFFFF
    return Int32(bitPattern: UInt32(diff))
}

/// Largest notification value for a negotiated ATT MTU, or 0 if payload cannot fit.
public func notificationCapacity(attMTU: Int) -> Int {
    let headerAndOverhead = WMRConstants.fragmentHeaderSize + WMRConstants.attNotifyOverhead
    guard attMTU > headerAndOverhead else { return 0 }
    let capacity = attMTU - WMRConstants.attNotifyOverhead
    return min(capacity, WMRConstants.maxNotificationSize)
}

/// Encodes one fragment of a frame starting at `offset`.
public func encodeFragment(frame: WmrFrame, offset: Int, capacity: Int) -> Data? {
    guard capacity > WMRConstants.fragmentHeaderSize else { return nil }
    guard offset >= 0, offset < frame.count else { return nil }

    var chunk = frame.count - offset
    let maxChunk = capacity - WMRConstants.fragmentHeaderSize
    if chunk > maxChunk {
        chunk = maxChunk
    }

    var packet = Data(count: WMRConstants.fragmentHeaderSize + chunk)
    packet[0] = WMRConstants.fragmentMagic
    packet[1] = frame.hand.rawValue

    let seqLE = frame.sequence.littleEndian
    withUnsafeBytes(of: seqLE) { packet.replaceSubrange(2..<6, with: $0) }

    let totalLE = UInt16(frame.count).littleEndian
    withUnsafeBytes(of: totalLE) { packet.replaceSubrange(6..<8, with: $0) }

    let offsetLE = UInt16(offset).littleEndian
    withUnsafeBytes(of: offsetLE) { packet.replaceSubrange(8..<10, with: $0) }

    let chunkLE = UInt16(chunk).littleEndian
    withUnsafeBytes(of: chunkLE) { packet.replaceSubrange(10..<12, with: $0) }

    let chunkData = frame.data.subdata(in: offset..<(offset + chunk))
    packet.replaceSubrange(WMRConstants.fragmentHeaderSize..<packet.count, with: chunkData)
    return packet
}

/// Encodes a complete frame into fragments for a given notification capacity.
public func encodeFrame(frame: WmrFrame, capacity: Int) -> [Data] {
    var fragments: [Data] = []
    var offset = 0
    while offset < frame.count {
        guard let fragment = encodeFragment(frame: frame, offset: offset, capacity: capacity) else { break }
        fragments.append(fragment)
        offset += fragment.count - WMRConstants.fragmentHeaderSize
    }
    return fragments
}

public enum ReassemblyResult: Equatable, Sendable {
    case partial
    case frameComplete(WmrFrame)
    case errShort
    case errMagic
    case errHand
    case errLength
    case errOutOfOrder
}

/// Slot maintaining reassembly state for one hand.
private final class ReassemblerSlot {
    var active: Bool = false
    var sequence: UInt32 = 0
    var total: Int = 0
    var received: Int = 0
    var buffer = Data(count: WMRConstants.maxFrameSize)
}

/// Reassembles FF11 notification fragments into complete WMR HID frames.
public final class WmrReassembler {
    private let slots: [ReassemblerSlot] = [ReassemblerSlot(), ReassemblerSlot()]

    public private(set) var framesComplete: [Int] = [0, 0]
    public private(set) var framesIncomplete: [Int] = [0, 0]
    public private(set) var errors: Int = 0
    public private(set) var lastFrame: WmrFrame?

    public init() {}

    private func abandon(handIndex: Int) {
        let s = slots[handIndex]
        if s.active {
            framesIncomplete[handIndex] += 1
            s.active = false
        }
    }

    /// Pushes a received notification fragment into the reassembler.
    public func push(_ packet: Data) -> ReassemblyResult {
        let size = packet.count
        guard size >= WMRConstants.fragmentHeaderSize else {
            errors += 1
            return .errShort
        }
        guard packet[0] == WMRConstants.fragmentMagic else {
            errors += 1
            return .errMagic
        }
        let handVal = packet[1]
        guard handVal < 2, let hand = WMRHand(rawValue: handVal) else {
            errors += 1
            return .errHand
        }
        let handIndex = Int(handVal)

        let sequence = packet.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt32.self).littleEndian }
        let total = Int(packet.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self).littleEndian })
        let offset = Int(packet.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt16.self).littleEndian })
        let chunk = Int(packet.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: UInt16.self).littleEndian })

        if chunk != size - WMRConstants.fragmentHeaderSize ||
            chunk == 0 ||
            total == 0 ||
            total > WMRConstants.maxFrameSize ||
            offset >= total ||
            chunk > total - offset {
            abandon(handIndex: handIndex)
            errors += 1
            return .errLength
        }

        let s = slots[handIndex]
        if offset == 0 {
            abandon(handIndex: handIndex)
            s.active = true
            s.sequence = sequence
            s.total = total
            s.received = 0
        } else if !s.active || s.sequence != sequence || s.total != total || s.received != offset {
            abandon(handIndex: handIndex)
            errors += 1
            return .errOutOfOrder
        }

        let payload = packet.subdata(in: WMRConstants.fragmentHeaderSize..<size)
        s.buffer.replaceSubrange(offset..<(offset + chunk), with: payload)
        s.received = offset + chunk

        if s.received < s.total {
            return .partial
        }

        s.active = false
        framesComplete[handIndex] += 1
        let completeData = s.buffer.subdata(in: 0..<s.total)
        let frame = WmrFrame(hand: hand, sequence: sequence, data: completeData)
        lastFrame = frame
        return .frameComplete(frame)
    }
}
