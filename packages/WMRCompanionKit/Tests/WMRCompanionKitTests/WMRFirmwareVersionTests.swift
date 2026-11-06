import XCTest
import CoreBluetooth
@testable import WMRCompanionKit

final class WMRFirmwareVersionTests: XCTestCase {
    private let allFeatures = WMRBridgeFeatures(
        rawStream: true,
        decodedStream: true,
        configBlock: true,
        batchedStream: true,
        echo: true,
        firmwareVersion: true,
        controllerControl: true
    )

    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    func testFeaturesMapTheFF10Characteristics() {
        let features = WMRBridgeFeatures(characteristicUUIDs: [
            CBUUID(string: "0000ff11-0000-1000-8000-00805f9b34fb"),
            WMRConstants.decodedCharUUID,
            WMRConstants.configCharUUID,
            WMRConstants.batchedCharUUID,
            WMRConstants.echoCharUUID,
            WMRConstants.versionCharUUID,
            WMRConstants.controllerControlCharUUID,
            CBUUID(string: "0000ABCD-0000-1000-8000-00805F9B34FB"),
        ])

        XCTAssertTrue(features.rawStream)
        XCTAssertTrue(features.decodedStream)
        XCTAssertTrue(features.configBlock)
        XCTAssertTrue(features.batchedStream)
        XCTAssertTrue(features.echo)
        XCTAssertTrue(features.firmwareVersion)
        XCTAssertTrue(features.controllerControl)
        XCTAssertEqual(features.offered, Set(WMRBridgeFeature.allCases))
        for feature in WMRBridgeFeature.allCases {
            XCTAssertTrue(features.supports(feature))
        }
    }

    func testFeaturesIgnoreUnknownUUIDsAndReportAnEmptyTable() {
        let features = WMRBridgeFeatures(characteristicUUIDs: [
            CBUUID(string: "0000ABCD-0000-1000-8000-00805F9B34FB"),
        ])

        XCTAssertTrue(features.offered.isEmpty)
        XCTAssertFalse(features.supports(.rawStream))
        XCTAssertTrue(WMRBridgeFeatures.none.offered.isEmpty)
    }

    func testOlderBridgeWithoutFF13ToFF17ReportsFF11AndFF12() {
        let features = WMRBridgeFeatures(characteristicUUIDs: [
            WMRConstants.streamCharUUID,
            WMRConstants.decodedCharUUID,
        ])

        XCTAssertTrue(features.rawStream)
        XCTAssertTrue(features.decodedStream)
        XCTAssertFalse(features.configBlock)
        XCTAssertFalse(features.batchedStream)
        XCTAssertFalse(features.echo)
        XCTAssertFalse(features.firmwareVersion)
        XCTAssertFalse(features.controllerControl)
    }

    func testParsesTheVersionStringFF16Serves() {
        let parsed = WMRFirmwareVersion.parse(
            bytes("v0.4.0-3-g41771f8"),
            features: allFeatures
        )

        XCTAssertEqual(parsed.version, "v0.4.0-3-g41771f8")
        XCTAssertTrue(parsed.hasVersion)
        XCTAssertFalse(parsed.isMalformed)
        XCTAssertEqual(parsed.features, allFeatures)
    }

    func testToleratesOneTrailingNulAndSurroundingWhitespace() {
        var data = bytes(" v1.2.3 ")
        data.append(0)

        let parsed = WMRFirmwareVersion.parse(data, features: allFeatures)

        XCTAssertEqual(parsed.version, "v1.2.3")
        XCTAssertFalse(parsed.isMalformed)
    }

    func testAcceptsThe31ByteMaximum() {
        let maximum = "v1.2.3-abcdef0123456789-abcdefg"
        XCTAssertEqual(maximum.utf8.count, WMRConstants.firmwareVersionMaxBytes)

        let parsed = WMRFirmwareVersion.parse(bytes(maximum), features: allFeatures)

        XCTAssertEqual(parsed.version, maximum)
        XCTAssertFalse(parsed.isMalformed)
    }

    func testAMissingFF16IsANormalStatusNotMalformed() {
        let features = WMRBridgeFeatures(
            rawStream: true,
            decodedStream: true
        )

        let parsed = WMRFirmwareVersion.parse(nil, features: features)

        XCTAssertNil(parsed.version)
        XCTAssertFalse(parsed.hasVersion)
        XCTAssertFalse(parsed.isMalformed)
        XCTAssertFalse(parsed.features.firmwareVersion)
        XCTAssertTrue(parsed.features.rawStream)

        let explicit = WMRFirmwareVersion.withoutVersion(features: features)
        XCTAssertNil(explicit.version)
        XCTAssertFalse(explicit.isMalformed)
    }

    func testMarksAnEmptyValueMalformed() {
        let parsed = WMRFirmwareVersion.parse(Data(), features: allFeatures)

        XCTAssertNil(parsed.version)
        XCTAssertTrue(parsed.isMalformed)
    }

    func testMarksAValueLongerThanTheDescriptorFieldMalformed() {
        let parsed = WMRFirmwareVersion.parse(
            bytes("v1.2.3-abcdef0123456789-abcdefgh"),
            features: allFeatures
        )

        XCTAssertNil(parsed.version)
        XCTAssertTrue(parsed.isMalformed)
    }

    func testMarksInvalidUTF8MalformedInsteadOfThrowing() {
        let parsed = WMRFirmwareVersion.parse(
            Data([0xFF, 0xFE, 0xFD]),
            features: allFeatures
        )

        XCTAssertNil(parsed.version)
        XCTAssertTrue(parsed.isMalformed)
    }

    func testMarksControlCharactersMalformedInsteadOfThrowing() {
        let parsed = WMRFirmwareVersion.parse(
            Data([0x76, 0x31, 0x01, 0x32]),
            features: allFeatures
        )

        XCTAssertNil(parsed.version)
        XCTAssertTrue(parsed.isMalformed)
    }
}
