import Foundation

/// FF17 write opcodes (WMR_Bridge `docs/PROTOCOL.md`, "Controller scan and
/// status v2"). These map 1:1 onto the ESP32 console actions; the firmware
/// keeps the guards (forget is refused while a hand is connected).
public enum WMRControllerCommand: UInt8, CaseIterable, Sendable {
    case discover = 0x01
    case connect = 0x02
    case disconnect = 0x03
    case forgetAddresses = 0x04
    case forgetBond = 0x05

    /// True for commands that address one hand (byte 1). The others ignore it.
    public var needsHand: Bool {
        switch self {
        case .connect, .disconnect, .forgetBond: return true
        case .discover, .forgetAddresses: return false
        }
    }
}

/// Result codes of an FF17 write. The firmware returns success as ATT 0x00
/// and a failure as ATT application error `0x80 + code`, and records the code
/// in the status v2 `last_result` field.
public enum WMRControllerResult: UInt8, CaseIterable, Sendable {
    case ok = 0x00
    case busy = 0x01
    case noAddress = 0x02
    case nothingToDo = 0x03
    case notConnected = 0x04
    case notEnabled = 0x05
    case invalidParam = 0x06
}

public enum WMRControllerAddressSource: UInt8, Sendable {
    case none = 0
    case compileOverride = 1
    case stored = 2

    init(code: UInt8) {
        self = WMRControllerAddressSource(rawValue: code) ?? .none
    }
}

public enum WMRControllerModel: UInt8, Sendable {
    case wmr = 0
    case psvr2 = 1
    case nintendoSwitch = 2
}

public enum WMRControllerDiscoveryState: UInt8, Sendable {
    case idle = 0
    case inquiry = 1
    case remoteNameRequests = 2
    case connectingDiscovered = 3

    init(code: UInt8) {
        self = WMRControllerDiscoveryState(rawValue: code) ?? .idle
    }
}

/// One hand's flags in a status v2 payload.
public struct WMRControllerHandStatus: Equatable, Sendable {
    public let connected: Bool
    public let connecting: Bool
    public let descriptorReceived: Bool
    public let addressSource: WMRControllerAddressSource
    /// nil when the bridge reports a model this kit does not know.
    public let model: WMRControllerModel?

    /// Last three bytes of the controller's Bluetooth address, zero when the
    /// hand has no address.
    public let addressTail: [UInt8]

    public init(
        connected: Bool,
        connecting: Bool,
        descriptorReceived: Bool,
        addressSource: WMRControllerAddressSource,
        model: WMRControllerModel?,
        addressTail: [UInt8]
    ) {
        self.connected = connected
        self.connecting = connecting
        self.descriptorReceived = descriptorReceived
        self.addressSource = addressSource
        self.model = model
        self.addressTail = addressTail
    }

    public var hasAddress: Bool {
        addressTail.contains { $0 != 0 }
    }
}

/// The 20-byte status v2 value returned by an FF17 read or notification.
public struct WMRControllerStatusV2: Equatable, Sendable {
    public static let length = WMRConstants.controllerStatusSize
    public static let version1 = WMRConstants.controllerStatusVersion

    public let version: UInt8

    /// Indexed by hand (0 = LEFT, 1 = RIGHT).
    public let hands: [WMRControllerHandStatus]
    public let discoveryState: WMRControllerDiscoveryState
    public let discoveryRound: UInt8

    /// Opcode of the last write command, nil if none.
    public let lastCommand: WMRControllerCommand?
    /// nil when the bridge reports a result code this kit does not know.
    public let lastResult: WMRControllerResult?

    public init(
        version: UInt8,
        hands: [WMRControllerHandStatus],
        discoveryState: WMRControllerDiscoveryState,
        discoveryRound: UInt8,
        lastCommand: WMRControllerCommand?,
        lastResult: WMRControllerResult?
    ) {
        self.version = version
        self.hands = hands
        self.discoveryState = discoveryState
        self.discoveryRound = discoveryRound
        self.lastCommand = lastCommand
        self.lastResult = lastResult
    }

    /// Returns nil if `data` is not the version 1 layout.
    public static func parse(_ data: Data) -> WMRControllerStatusV2? {
        let bytes = [UInt8](data)
        guard bytes.count >= length,
              bytes[0] == WMRConstants.controllerStatusVersion
        else { return nil }

        func hand(at base: Int) -> WMRControllerHandStatus {
            let flags = bytes[base]
            return WMRControllerHandStatus(
                connected: flags & 0x01 != 0,
                connecting: flags & 0x02 != 0,
                descriptorReceived: flags & 0x04 != 0,
                addressSource: WMRControllerAddressSource(code: bytes[base + 1]),
                model: WMRControllerModel(rawValue: bytes[base + 2]),
                addressTail: [bytes[base + 3], bytes[base + 4], bytes[base + 5]]
            )
        }

        return WMRControllerStatusV2(
            version: bytes[0],
            hands: [hand(at: 1), hand(at: 8)],
            discoveryState: WMRControllerDiscoveryState(code: bytes[15]),
            discoveryRound: bytes[16],
            lastCommand: WMRControllerCommand(rawValue: bytes[17]),
            lastResult: WMRControllerResult(rawValue: bytes[18])
        )
    }
}

public enum WMRControllerCommandError: Error, Equatable, Sendable {
    /// A hand-addressed command was encoded without a hand.
    case missingHand
}

/// Encodes an FF17 write: the opcode, plus the hand for commands that take
/// one (0 = LEFT, 1 = RIGHT).
///
/// Throws `WMRControllerCommandError.missingHand` for a command that needs a
/// hand but was given none, so a caller cannot send a malformed command.
public func encodeControllerCommand(
    _ command: WMRControllerCommand,
    hand: WMRHand? = nil
) throws -> Data {
    guard command.needsHand else {
        return Data([command.rawValue])
    }
    guard let hand else {
        throw WMRControllerCommandError.missingHand
    }
    return Data([command.rawValue, hand.rawValue])
}
