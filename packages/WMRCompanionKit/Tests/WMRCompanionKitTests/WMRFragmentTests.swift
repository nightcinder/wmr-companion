import XCTest
@testable import WMRCompanionKit

final class WMRFragmentTests: XCTestCase {
    func testNotificationCapacity() {
        XCTAssertEqual(notificationCapacity(attMTU: 10), 0)
        XCTAssertEqual(notificationCapacity(attMTU: 15), 0)
        XCTAssertEqual(notificationCapacity(attMTU: 23), 20)
        XCTAssertEqual(notificationCapacity(attMTU: 64), 61)
        XCTAssertEqual(notificationCapacity(attMTU: 247), 244)
        XCTAssertEqual(notificationCapacity(attMTU: 517), 244)
    }

    func testSequenceDelta() {
        XCTAssertEqual(sequenceDelta(10, 11), 1)
        XCTAssertEqual(sequenceDelta(10, 10), 0)
        XCTAssertEqual(sequenceDelta(11, 10), -1)
        XCTAssertEqual(sequenceDelta(0xFFFFFFFF, 0), 1)
        XCTAssertEqual(sequenceDelta(0, 0xFFFFFFFF), -1)
    }

    func testSingleFragmentFrameRoundTrip() {
        let payload = Data([0xA1, 0x01] + Array(repeating: UInt8(42), count: 44))
        let frame = WmrFrame(hand: .left, sequence: 100, data: payload)

        let fragments = encodeFrame(frame: frame, capacity: 64)
        XCTAssertEqual(fragments.count, 1)

        let reassembler = WmrReassembler()
        let result = reassembler.push(fragments[0])

        XCTAssertEqual(result, .frameComplete(frame))
        XCTAssertEqual(reassembler.framesComplete[0], 1)
        XCTAssertEqual(reassembler.framesIncomplete[0], 0)
        XCTAssertEqual(reassembler.errors, 0)
    }

    func testMultiFragmentFrameRoundTrip() {
        let payload = Data([0xA1, 0x01] + Array(repeating: UInt8(99), count: 44))
        let frame = WmrFrame(hand: .right, sequence: 200, data: payload)

        // Capacity 20: 12 bytes header + 8 bytes payload per fragment
        let fragments = encodeFrame(frame: frame, capacity: 20)
        XCTAssertGreaterThan(fragments.count, 1)

        let reassembler = WmrReassembler()
        var completedFrame: WmrFrame?

        for f in fragments {
            let res = reassembler.push(f)
            if case .frameComplete(let comp) = res {
                completedFrame = comp
            }
        }

        XCTAssertEqual(completedFrame, frame)
        XCTAssertEqual(reassembler.framesComplete[1], 1)
        XCTAssertEqual(reassembler.errors, 0)
    }

    func testMalformedFragments() {
        let reassembler = WmrReassembler()

        // Too short (< 12 bytes)
        XCTAssertEqual(reassembler.push(Data([0x52, 0x00])), .errShort)

        // Bad magic
        var badMagic = Data(count: 14)
        badMagic[0] = 0x51
        XCTAssertEqual(reassembler.push(badMagic), .errMagic)

        // Bad hand (2)
        var badHand = Data(count: 14)
        badHand[0] = 0x52
        badHand[1] = 2
        XCTAssertEqual(reassembler.push(badHand), .errHand)
    }
}
