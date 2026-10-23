import Foundation

/// Controller hand designation.
public enum WMRHand: UInt8, CaseIterable, CustomStringConvertible, Sendable {
    case left = 0
    case right = 1

    public var description: String {
        switch self {
        case .left: return "LEFT"
        case .right: return "RIGHT"
        }
    }
}

/// Digital button state bitmask matching the controller report and decoded stream.
public struct WMRButtonState: OptionSet, Sendable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let thumbstickClick = WMRButtonState(rawValue: 0x01)
    public static let home            = WMRButtonState(rawValue: 0x02)
    public static let menu            = WMRButtonState(rawValue: 0x04)
    public static let squeeze         = WMRButtonState(rawValue: 0x08)
    public static let trackpadClick   = WMRButtonState(rawValue: 0x10)
    public static let btPairing       = WMRButtonState(rawValue: 0x20)
    public static let trackpadTouch   = WMRButtonState(rawValue: 0x40)

    public var description: String {
        var names: [String] = []
        if contains(.thumbstickClick) { names.append("stickClick") }
        if contains(.home) { names.append("home") }
        if contains(.menu) { names.append("menu") }
        if contains(.squeeze) { names.append("squeeze") }
        if contains(.trackpadClick) { names.append("padClick") }
        if contains(.btPairing) { names.append("pairing") }
        if contains(.trackpadTouch) { names.append("padTouch") }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}

/// BLE stream subscription mode.
/// Note: FF11, FF12, and FF14 are mutually exclusive on the bridge.
public enum WMRStreamMode: Int, CaseIterable, CustomStringConvertible, Sendable {
    case none = 0
    case rawFF11 = 1
    case decodedFF12 = 2
    case batchedFF14 = 3

    public var description: String {
        switch self {
        case .none: return "None (Echo only)"
        case .rawFF11: return "Raw HID (FF11)"
        case .decodedFF12: return "Decoded (FF12)"
        case .batchedFF14: return "Batched Decoded (FF14)"
        }
    }
}

/// Connection lifecycle states for the BLE central manager.
public enum WMRConnectionState: Equatable, Sendable {
    case disconnected
    case scanning
    case connecting
    case discoveringServices
    case ready
    case failed(String)
}

/// Comprehensive high-level controller telemetry state.
public struct WMRControllerState: Sendable {
    public let hand: WMRHand
    public let isConnected: Bool
    public let sequence: UInt32
    public let rxTimeUs: UInt64
    public let deviceTicks: UInt32
    public let buttons: WMRButtonState
    public let stick: (x: Int16, y: Int16)
    public let trackpad: (x: Int16, y: Int16)
    public let trigger: UInt8
    public let battery: UInt8
    public let temperatureRaw: Int16
    public let gyro: (x: Float, y: Float, z: Float)
    public let accel: (x: Float, y: Float, z: Float)
    public let orientation: (w: Float, x: Float, y: Float, z: Float)
    public let euler: (roll: Float, pitch: Float, yaw: Float)
    public let packetRateHz: Double
    public let lossPercent: Double
    public let sequenceGaps: Int

    public init(
        hand: WMRHand,
        isConnected: Bool = false,
        sequence: UInt32 = 0,
        rxTimeUs: UInt64 = 0,
        deviceTicks: UInt32 = 0,
        buttons: WMRButtonState = [],
        stick: (x: Int16, y: Int16) = (0, 0),
        trackpad: (x: Int16, y: Int16) = (0, 0),
        trigger: UInt8 = 0,
        battery: UInt8 = 0,
        temperatureRaw: Int16 = 0,
        gyro: (x: Float, y: Float, z: Float) = (0, 0, 0),
        accel: (x: Float, y: Float, z: Float) = (0, 0, 0),
        orientation: (w: Float, x: Float, y: Float, z: Float) = (1, 0, 0, 0),
        euler: (roll: Float, pitch: Float, yaw: Float) = (0, 0, 0),
        packetRateHz: Double = 0,
        lossPercent: Double = 0,
        sequenceGaps: Int = 0
    ) {
        self.hand = hand
        self.isConnected = isConnected
        self.sequence = sequence
        self.rxTimeUs = rxTimeUs
        self.deviceTicks = deviceTicks
        self.buttons = buttons
        self.stick = stick
        self.trackpad = trackpad
        self.trigger = trigger
        self.battery = battery
        self.temperatureRaw = temperatureRaw
        self.gyro = gyro
        self.accel = accel
        self.orientation = orientation
        self.euler = euler
        self.packetRateHz = packetRateHz
        self.lossPercent = lossPercent
        self.sequenceGaps = sequenceGaps
    }
}
