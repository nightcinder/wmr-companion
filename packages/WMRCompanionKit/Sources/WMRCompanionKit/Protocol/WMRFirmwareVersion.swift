import Foundation
import CoreBluetooth

/// The FF characteristics a bridge offers.
///
/// This is the capability matrix: a characteristic that is present works
/// regardless of the FF16 version string, and one that is absent cannot be
/// used. The version string is informational; do not parse it to decide what
/// the bridge supports.
public enum WMRBridgeFeature: CaseIterable, Hashable, Sendable {
    /// FF11: raw fragmented frames, read status and notify.
    case rawStream

    /// FF12: decoded 56-byte records.
    case decodedStream

    /// FF13: controller config block (calibration).
    case configBlock

    /// FF14: batched decoded records (needs ATT MTU of at least 61).
    case batchedStream

    /// FF15: echo / round-trip measurement.
    case echo

    /// FF16: the packaged firmware version.
    case firmwareVersion

    /// FF17: controller scan and status v2.
    case controllerControl
}

/// Which characteristics the connected bridge's GATT table offers.
public struct WMRBridgeFeatures: Equatable, Sendable {
    public let rawStream: Bool
    public let decodedStream: Bool
    public let configBlock: Bool
    public let batchedStream: Bool
    public let echo: Bool
    public let firmwareVersion: Bool
    public let controllerControl: Bool

    public init(
        rawStream: Bool = false,
        decodedStream: Bool = false,
        configBlock: Bool = false,
        batchedStream: Bool = false,
        echo: Bool = false,
        firmwareVersion: Bool = false,
        controllerControl: Bool = false
    ) {
        self.rawStream = rawStream
        self.decodedStream = decodedStream
        self.configBlock = configBlock
        self.batchedStream = batchedStream
        self.echo = echo
        self.firmwareVersion = firmwareVersion
        self.controllerControl = controllerControl
    }

    /// A bridge whose characteristics were not discovered.
    public static let none = WMRBridgeFeatures()

    /// Derives the set from the characteristic UUIDs of the FF10 service.
    /// Unknown UUIDs are ignored.
    public init(characteristicUUIDs: [CBUUID]) {
        let seen = Set(characteristicUUIDs.map { $0.uuidString.uppercased() })
        self.init(
            rawStream: seen.contains(WMRConstants.streamCharUUID.uuidString),
            decodedStream: seen.contains(WMRConstants.decodedCharUUID.uuidString),
            configBlock: seen.contains(WMRConstants.configCharUUID.uuidString),
            batchedStream: seen.contains(WMRConstants.batchedCharUUID.uuidString),
            echo: seen.contains(WMRConstants.echoCharUUID.uuidString),
            firmwareVersion: seen.contains(WMRConstants.versionCharUUID.uuidString),
            controllerControl: seen.contains(WMRConstants.controllerControlCharUUID.uuidString)
        )
    }

    /// Whether `feature` is offered.
    public func supports(_ feature: WMRBridgeFeature) -> Bool {
        switch feature {
        case .rawStream: return rawStream
        case .decodedStream: return decodedStream
        case .configBlock: return configBlock
        case .batchedStream: return batchedStream
        case .echo: return echo
        case .firmwareVersion: return firmwareVersion
        case .controllerControl: return controllerControl
        }
    }

    /// The offered features, in characteristic order.
    public var offered: Set<WMRBridgeFeature> {
        Set(WMRBridgeFeature.allCases.filter(supports))
    }
}

/// What the bridge reports about itself: its FF16 version string, when FF16
/// exists, and its feature set from the GATT table.
///
/// A bridge without FF16 is an older firmware and a normal status, not an
/// error. A value that cannot be decoded is marked `isMalformed` and the link
/// keeps working; neither case throws.
public struct WMRFirmwareVersion: Equatable, Sendable {
    /// The FF16 value, trimmed of a trailing NUL and surrounding whitespace.
    /// Nil when the bridge has no FF16 or the value was malformed.
    public let version: String?

    /// True when FF16 was present but its value was empty, longer than
    /// `WMRConstants.firmwareVersionMaxBytes`, not valid UTF-8 or contained
    /// control characters. Informational: the link is unaffected.
    public let isMalformed: Bool

    /// The feature matrix derived from the GATT table.
    public let features: WMRBridgeFeatures

    public init(
        features: WMRBridgeFeatures,
        version: String? = nil,
        isMalformed: Bool = false
    ) {
        self.features = features
        self.version = version
        self.isMalformed = isMalformed
    }

    /// No usable version string: FF16 is absent (older firmware) or its read
    /// failed. `features` still describe what the bridge offers.
    public static func withoutVersion(features: WMRBridgeFeatures) -> WMRFirmwareVersion {
        WMRFirmwareVersion(features: features)
    }

    /// Whether a usable version string was reported.
    public var hasVersion: Bool { version != nil }

    /// Decodes an FF16 read.
    ///
    /// `data` is nil when the bridge has no FF16 or the read failed; that is
    /// not malformed. The firmware writes no terminator, but one trailing NUL
    /// is tolerated because a platform stack may add one. Unknown bytes are
    /// not fatal: the version becomes nil and `isMalformed` is set.
    public static func parse(_ data: Data?, features: WMRBridgeFeatures) -> WMRFirmwareVersion {
        guard let data else {
            return .withoutVersion(features: features)
        }

        var bytes = [UInt8](data)
        if bytes.last == 0 {
            bytes.removeLast()
        }
        guard !bytes.isEmpty, bytes.count <= WMRConstants.firmwareVersionMaxBytes else {
            return WMRFirmwareVersion(features: features, isMalformed: true)
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            return WMRFirmwareVersion(features: features, isMalformed: true)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hasControlCharacter(trimmed) else {
            return WMRFirmwareVersion(features: features, isMalformed: true)
        }
        return WMRFirmwareVersion(features: features, version: trimmed)
    }

    private static func hasControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
