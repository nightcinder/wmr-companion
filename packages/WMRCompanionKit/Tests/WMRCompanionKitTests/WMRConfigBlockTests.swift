import XCTest
@testable import WMRCompanionKit

final class WMRConfigBlockTests: XCTestCase {
    func testCrc32StandardCheck() {
        let ascii123456789 = "123456789".data(using: .ascii)!
        XCTAssertEqual(crc32(ascii123456789), 0xCBF43926)
    }

    func testCursorEncoding() {
        let cursor = encodeConfigCursor(hand: .right, offset: 496)
        XCTAssertEqual(cursor.count, 5)
        XCTAssertEqual(cursor[0], 1) // right
        let offLE = UInt32(496).littleEndian
        let expectedBytes = withUnsafeBytes(of: offLE) { Array($0) }
        XCTAssertEqual(Array(cursor[1..<5]), expectedBytes)
    }

    func testWindowRoundTrip() {
        let dummyBlob = "Hello WMR Configuration Blob".data(using: .utf8)!
        let encoded = encodeConfigWindow(hand: .left, state: .ready, blob: dummyBlob, offset: 0)

        let parsed = parseConfigWindow(encoded)
        guard case .success(let win) = parsed else {
            XCTFail("Failed to parse config window")
            return
        }

        XCTAssertEqual(win.hand, .left)
        XCTAssertEqual(win.state, .ready)
        XCTAssertEqual(win.totalLen, UInt32(dummyBlob.count))
        XCTAssertEqual(win.offset, 0)
        XCTAssertEqual(win.crc32, crc32(dummyBlob))
        XCTAssertEqual(win.data, dummyBlob)
    }
}
