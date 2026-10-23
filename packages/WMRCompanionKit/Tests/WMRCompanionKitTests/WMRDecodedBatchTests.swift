import XCTest
@testable import WMRCompanionKit

final class WMRDecodedBatchTests: XCTestCase {
    func testBatchMaxCount() {
        XCTAssertEqual(batchMaxCount(attMTU: 0), 0)
        XCTAssertEqual(batchMaxCount(attMTU: 23), 0)
        XCTAssertEqual(batchMaxCount(attMTU: 59), 0)
        XCTAssertEqual(batchMaxCount(attMTU: 60), 0)
        XCTAssertEqual(batchMaxCount(attMTU: 61), 1)
        XCTAssertEqual(batchMaxCount(attMTU: 116), 1)
        XCTAssertEqual(batchMaxCount(attMTU: 117), 2)
        XCTAssertEqual(batchMaxCount(attMTU: 247), 4)
        XCTAssertEqual(batchMaxCount(attMTU: 517), 9)
        XCTAssertEqual(batchMaxCount(attMTU: 1000), 9)
    }

    func testBatchRoundTrip() {
        let rec1 = DecodedRecord(
            hand: .left,
            sequence: 1,
            rxTimeUs: 1000,
            deviceTicks: 50000,
            gyro: (0.1, 0.2, 0.3),
            accel: (0.0, 9.8, 0.0)
        )
        let rec2 = DecodedRecord(
            hand: .right,
            sequence: 2,
            rxTimeUs: 1005,
            deviceTicks: 55000,
            gyro: (-0.1, -0.2, -0.3),
            accel: (0.0, -9.8, 0.0)
        )

        let batchPayload = encodeDecodedBatch([rec1, rec2])
        XCTAssertEqual(batchPayload.count, 2 + 2 * 56)
        XCTAssertEqual(batchPayload[0], WMRConstants.batchVersion)
        XCTAssertEqual(batchPayload[1], 2)

        let parsed = parseDecodedBatch(batchPayload)
        guard case .success(let records) = parsed else {
            XCTFail("Failed to parse batch")
            return
        }

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0], rec1)
        XCTAssertEqual(records[1], rec2)
    }

    func testBatchRejections() {
        // Too short (< 58 bytes)
        XCTAssertEqual(parseDecodedBatch(Data([0x02, 0x01])), .failure(.tooShort))

        // Wrong version (byte 0 != 2)
        var badVer = Data(count: 58)
        badVer[0] = 0x01
        badVer[1] = 0x01
        XCTAssertEqual(parseDecodedBatch(badVer), .failure(.unknownVersion))

        // Empty batch (count == 0)
        var emptyBatch = Data(count: 58)
        emptyBatch[0] = 0x02
        emptyBatch[1] = 0x00
        XCTAssertEqual(parseDecodedBatch(emptyBatch), .failure(.emptyBatch))

        // Wrong length
        var wrongLen = Data(count: 60)
        wrongLen[0] = 0x02
        wrongLen[1] = 0x01
        XCTAssertEqual(parseDecodedBatch(wrongLen), .failure(.wrongLength))
    }
}
