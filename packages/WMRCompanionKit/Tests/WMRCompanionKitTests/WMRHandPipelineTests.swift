import XCTest
@testable import WMRCompanionKit

final class WMRHandPipelineTests: XCTestCase {
    func testPipelineIngestion() {
        let pipeline = WMRHandPipeline(hand: .left)

        let rec1 = DecodedRecord(
            hand: .left,
            sequence: 1,
            rxTimeUs: 1000000,
            deviceTicks: 100000,
            gyro: (0, 0, 0),
            accel: (0, 0, 9.81)
        )
        let state1 = pipeline.push(record: rec1)
        XCTAssertEqual(state1.hand, .left)
        XCTAssertEqual(state1.sequence, 1)
        XCTAssertEqual(pipeline.sequenceGaps, 0)

        // Consecutive record: 5ms later (50,000 ticks)
        let rec2 = DecodedRecord(
            hand: .left,
            sequence: 2,
            rxTimeUs: 1005000,
            deviceTicks: 150000,
            gyro: (0, 0, 0),
            accel: (0, 0, 9.81)
        )
        let state2 = pipeline.push(record: rec2)
        XCTAssertEqual(state2.sequence, 2)
        XCTAssertEqual(pipeline.sequenceGaps, 0)
        XCTAssertEqual(pipeline.missingTicksTotal, 0)

        // Gap in sequence: sequence skips to 5 (3 missing)
        let rec5 = DecodedRecord(
            hand: .left,
            sequence: 5,
            rxTimeUs: 1020000,
            deviceTicks: 300000, // 150,000 ticks later (~3 samples)
            gyro: (0, 0, 0),
            accel: (0, 0, 9.81)
        )
        let state5 = pipeline.push(record: rec5)
        XCTAssertEqual(state5.sequence, 5)
        XCTAssertEqual(pipeline.sequenceGaps, 2) // skipped 3, 4
        XCTAssertGreaterThan(pipeline.missingTicksTotal, 0)
    }

    func testDeviceTickWrapping() {
        let pipeline = WMRHandPipeline(hand: .right)

        let rec1 = DecodedRecord(
            hand: .right,
            sequence: 10,
            rxTimeUs: 1000000,
            deviceTicks: 0xFFFFFF00,
            gyro: (0, 0, 0),
            accel: (0, 0, 9.81)
        )
        _ = pipeline.push(record: rec1)

        // Wrap across 32-bit boundary (e.g. 50,000 ticks later)
        let nextTicks = UInt32((UInt64(0xFFFFFF00) + 50000) & 0xFFFFFFFF)
        let rec2 = DecodedRecord(
            hand: .right,
            sequence: 11,
            rxTimeUs: 1005000,
            deviceTicks: nextTicks,
            gyro: (0, 0, 0),
            accel: (0, 0, 9.81)
        )
        let state2 = pipeline.push(record: rec2)
        XCTAssertEqual(state2.sequence, 11)
        XCTAssertEqual(pipeline.missingTicksTotal, 0)
    }
}
