import XCTest
@testable import WMRCompanionKit

final class WMRControllerControlTests: XCTestCase {
    private func statusBytes(
        leftFlags: UInt8 = 0,
        leftSource: UInt8 = 0,
        leftModel: UInt8 = 0,
        leftTail: [UInt8] = [0, 0, 0],
        rightFlags: UInt8 = 0,
        rightSource: UInt8 = 0,
        rightModel: UInt8 = 0,
        rightTail: [UInt8] = [0, 0, 0],
        discoveryState: UInt8 = 0,
        discoveryRound: UInt8 = 0,
        lastCommand: UInt8 = 0,
        lastResult: UInt8 = 0
    ) -> Data {
        Data([
            1,
            leftFlags,
            leftSource,
            leftModel,
            leftTail[0], leftTail[1], leftTail[2],
            0,
            rightFlags,
            rightSource,
            rightModel,
            rightTail[0], rightTail[1], rightTail[2],
            0,
            discoveryState,
            discoveryRound,
            lastCommand,
            lastResult,
            0,
        ])
    }

    func testOneByteCommandsCarryOnlyTheOpcode() throws {
        XCTAssertEqual(try encodeControllerCommand(.discover), Data([0x01]))
        XCTAssertEqual(try encodeControllerCommand(.forgetAddresses), Data([0x04]))
    }

    func testHandCommandsCarryTheHand() throws {
        XCTAssertEqual(try encodeControllerCommand(.connect, hand: .right), Data([0x02, 0x01]))
        XCTAssertEqual(try encodeControllerCommand(.forgetBond, hand: .left), Data([0x05, 0x00]))
    }

    func testOneByteCommandsIgnoreAProvidedHand() throws {
        XCTAssertEqual(try encodeControllerCommand(.discover, hand: .right), Data([0x01]))
    }

    func testRefusesAHandCommandWithoutAHand() {
        XCTAssertThrowsError(try encodeControllerCommand(.connect)) { error in
            XCTAssertEqual(error as? WMRControllerCommandError, .missingHand)
        }
    }

    func testParsesBothHandsDiscoveryAndTheLastCommand() throws {
        let data = statusBytes(
            leftFlags: 0x05,
            leftSource: 2,
            leftTail: [0x11, 0x22, 0x33],
            rightFlags: 0x02,
            rightModel: 1,
            discoveryState: 1,
            discoveryRound: 3,
            lastCommand: 0x02,
            lastResult: 0x01
        )

        let status = try XCTUnwrap(WMRControllerStatusV2.parse(data))

        XCTAssertEqual(status.version, 1)
        XCTAssertEqual(status.hands.count, 2)
        XCTAssertTrue(status.hands[0].connected)
        XCTAssertTrue(status.hands[0].descriptorReceived)
        XCTAssertFalse(status.hands[0].connecting)
        XCTAssertEqual(status.hands[0].addressSource, .stored)
        XCTAssertEqual(status.hands[0].model, .wmr)
        XCTAssertEqual(status.hands[0].addressTail, [0x11, 0x22, 0x33])
        XCTAssertTrue(status.hands[0].hasAddress)
        XCTAssertFalse(status.hands[1].connected)
        XCTAssertTrue(status.hands[1].connecting)
        XCTAssertEqual(status.hands[1].addressSource, .none)
        XCTAssertEqual(status.hands[1].model, .psvr2)
        XCTAssertEqual(status.hands[1].addressTail, [0, 0, 0])
        XCTAssertFalse(status.hands[1].hasAddress)
        XCTAssertEqual(status.discoveryState, .inquiry)
        XCTAssertEqual(status.discoveryRound, 3)
        XCTAssertEqual(status.lastCommand, .connect)
        XCTAssertEqual(status.lastResult, .busy)
    }

    func testModelCodeTwoIsNintendoSwitch() throws {
        let status = try XCTUnwrap(
            WMRControllerStatusV2.parse(statusBytes(leftModel: 2))
        )

        XCTAssertEqual(status.hands[0].model, .nintendoSwitch)
    }

    func testAnUnknownLastCommandResultAndModelAreNil() throws {
        let status = try XCTUnwrap(
            WMRControllerStatusV2.parse(
                statusBytes(
                    leftModel: 0x7F,
                    lastCommand: 0x7F,
                    lastResult: 0x7F
                )
            )
        )

        XCTAssertNil(status.hands[0].model)
        XCTAssertNil(status.lastCommand)
        XCTAssertNil(status.lastResult)
    }

    func testAShortOrFutureVersionValueIsRejectedNotGuessed() {
        XCTAssertNil(WMRControllerStatusV2.parse(Data(repeating: 0, count: 19)))

        var future = statusBytes()
        future[0] = 2
        XCTAssertNil(WMRControllerStatusV2.parse(future))
    }
}
