import XCTest
@testable import WMRCompanionKit

final class WMRDecodedRecordTests: XCTestCase {
    let golden = Data([
        0x01, 0x01, 0x00, 0x06, // version, hand, flags, buttons
        0x04, 0x03, 0x02, 0x01, // sequence 0x01020304
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, // rx_time_us
        0xDD, 0xCC, 0xBB, 0xAA, // device_ticks
        0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x3F,
        0x00, 0x00, 0x80, 0x40, 0x00, 0x00, 0x00, 0xC1, 0x00, 0x00, 0x00, 0x00,
        0xFE, 0xFF, // temperature -2
        0xFF, 0x7F, 0x01, 0x80, // stick 32767 -32767
        0x00, 0x00, 0x00, 0x40, // trackpad 0 16384
        0xFF, 0x7B // trigger, battery
    ])

    func testGoldenBytesCount() {
        XCTAssertEqual(golden.count, 56)
    }

    func testParseGoldenRecord() {
        let result = parseDecodedRecord(golden)
        guard case .success(let r) = result else {
            XCTFail("Failed to parse golden record")
            return
        }

        XCTAssertEqual(r.hand, .right)
        XCTAssertEqual(r.flags, 0)
        XCTAssertFalse(r.calibrated)
        XCTAssertEqual(r.buttons.rawValue, 0x06)
        XCTAssertTrue(r.buttons.contains(.home))
        XCTAssertTrue(r.buttons.contains(.menu))
        XCTAssertEqual(r.sequence, 0x01020304)
        XCTAssertEqual(r.rxTimeUs, 0x1122334455667788)
        XCTAssertEqual(r.deviceTicks, 0xAABBCCDD)
        XCTAssertEqual(r.gyro.x, 1.0)
        XCTAssertEqual(r.gyro.y, -2.0)
        XCTAssertEqual(r.gyro.z, 0.5)
        XCTAssertEqual(r.accel.x, 4.0)
        XCTAssertEqual(r.accel.y, -8.0)
        XCTAssertEqual(r.accel.z, 0.0)
        XCTAssertEqual(r.temperatureRaw, -2)
        XCTAssertEqual(r.stick.x, 32767)
        XCTAssertEqual(r.stick.y, -32767)
        XCTAssertEqual(r.trackpad.x, 0)
        XCTAssertEqual(r.trackpad.y, 16384)
        XCTAssertEqual(r.trigger, 0xFF)
        XCTAssertEqual(r.battery, 0x7B)
    }

    func testEncodeReproducesGolden() {
        guard case .success(let r) = parseDecodedRecord(golden) else {
            XCTFail("Failed to parse")
            return
        }
        let encoded = encodeDecodedRecord(r)
        XCTAssertEqual(encoded, golden)
    }

    func testRejections() {
        // Truncated
        XCTAssertEqual(parseDecodedRecord(golden.subdata(in: 0..<55)), .failure(.wrongLength))
        // Oversized
        var over = golden
        over.append(0x00)
        XCTAssertEqual(parseDecodedRecord(over), .failure(.wrongLength))

        // Unknown version
        var badVer = golden
        badVer[0] = 0x02
        XCTAssertEqual(parseDecodedRecord(badVer), .failure(.unknownVersion))

        // Bad hand
        var badHand = golden
        badHand[1] = 0x02
        XCTAssertEqual(parseDecodedRecord(badHand), .failure(.badHand))
    }

    func testTickDelta() {
        XCTAssertEqual(tickDelta(100, 150), 50)
        XCTAssertEqual(tickDelta(0xFFFFFFFF, 0), 1)
        XCTAssertEqual(tickDelta(0xFFFFFFFE, 1), 3)
    }
}
