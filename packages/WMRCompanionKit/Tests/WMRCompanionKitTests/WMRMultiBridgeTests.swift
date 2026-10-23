import XCTest
@testable import WMRCompanionKit

final class WMRMultiBridgeTests: XCTestCase {
    func testMultiBridgeCoordination() {
        let leftSession = WMRBridgeSession()
        let rightSession = WMRBridgeSession()
        let multi = WMRMultiBridgeSession(leftBridgeSession: leftSession, rightBridgeSession: rightSession)

        let expLeft = expectation(description: "Left controller state")
        let expRight = expectation(description: "Right controller state")

        var receivedLeft: WMRControllerState?
        var receivedRight: WMRControllerState?

        let cancelLeft = multi.leftStatePublisher.sink { state in
            if state.sequence == 42 {
                receivedLeft = state
                expLeft.fulfill()
            }
        }
        let cancelRight = multi.rightStatePublisher.sink { state in
            if state.sequence == 99 {
                receivedRight = state
                expRight.fulfill()
            }
        }

        // Send left record on left session
        let recLeft = DecodedRecord(
            hand: .left,
            sequence: 42,
            rxTimeUs: 1000,
            deviceTicks: 50000,
            gyro: (0, 0, 0),
            accel: (0, 0, 9.81)
        )
        _ = leftSession.leftPipeline.push(record: recLeft)
        leftSession.leftStatePublisher.send(leftSession.leftPipeline.latestState!)

        // Send right record on right session
        let recRight = DecodedRecord(
            hand: .right,
            sequence: 99,
            rxTimeUs: 2000,
            deviceTicks: 60000,
            gyro: (0, 0, 0),
            accel: (0, 0, -9.81)
        )
        _ = rightSession.rightPipeline.push(record: recRight)
        rightSession.rightStatePublisher.send(rightSession.rightPipeline.latestState!)

        wait(for: [expLeft, expRight], timeout: 2.0)

        XCTAssertEqual(receivedLeft?.sequence, 42)
        XCTAssertEqual(receivedRight?.sequence, 99)

        cancelLeft.cancel()
        cancelRight.cancel()
    }
}
