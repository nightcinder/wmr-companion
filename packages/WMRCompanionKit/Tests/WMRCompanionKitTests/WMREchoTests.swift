import XCTest
@testable import WMRCompanionKit

final class WMREchoTests: XCTestCase {
    func testEchoRequestEncoding() {
        let req = encodeEchoRequest(pingId: 0x1234)
        XCTAssertEqual(req.count, 4)
        XCTAssertEqual(req[0], WMRConstants.echoVersion)
        XCTAssertEqual(req[1], 0)
        XCTAssertEqual(req[2], 0x34)
        XCTAssertEqual(req[3], 0x12)
    }

    func testEchoAnswerParsing() {
        // Golden answer from firmware spec:
        // version 1, reserved 0, ping_id 0x0001, rx_time 0x0000000000001000,
        // turnaround 0x00000064 (100 us), queue_depth 0x0002, reserved
        var answerData = Data(count: 20)
        answerData[0] = 1
        answerData[1] = 0
        answerData[2] = 0x01
        answerData[3] = 0x00
        let rxLE = UInt64(4096).littleEndian
        withUnsafeBytes(of: rxLE) { answerData.replaceSubrange(4..<12, with: $0) }
        let turnLE = UInt32(100).littleEndian
        withUnsafeBytes(of: turnLE) { answerData.replaceSubrange(12..<16, with: $0) }
        let qLE = UInt16(2).littleEndian
        withUnsafeBytes(of: qLE) { answerData.replaceSubrange(16..<18, with: $0) }

        let result = parseEchoAnswer(answerData)
        guard case .success(let ans) = result else {
            XCTFail("Failed to parse echo answer")
            return
        }

        XCTAssertEqual(ans.pingId, 1)
        XCTAssertEqual(ans.rxTimeUs, 4096)
        XCTAssertEqual(ans.turnaroundUs, 100)
        XCTAssertEqual(ans.queueDepth, 2)
    }

    func testEchoRoundTrip() {
        let original = EchoAnswer(pingId: 42, rxTimeUs: 987654321, turnaroundUs: 430, queueDepth: 5)
        let encoded = encodeEchoAnswer(original)
        XCTAssertEqual(encoded.count, 20)

        let parsed = parseEchoAnswer(encoded)
        guard case .success(let decoded) = parsed else {
            XCTFail("Failed round trip")
            return
        }
        XCTAssertEqual(decoded, original)
    }
}
