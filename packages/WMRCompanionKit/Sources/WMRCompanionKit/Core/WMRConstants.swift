import Foundation
import CoreBluetooth

/// GATT constants and protocol wire definitions for the WMR Bridge firmware.
///
/// Source of truth: WMR_Bridge `wmr_bridge.gatt` and `docs/PROTOCOL.md`.
public enum WMRConstants {
    /// Default advertising device name for the bridge.
    public static let defaultDeviceName = "WMR Bridge"

    // MARK: - CoreBluetooth CBUUID Identifiers

    /// Primary GATT service UUID (16-bit alias 0xFF10).
    public static let serviceUUID = CBUUID(string: "0000FF10-0000-1000-8000-00805F9B34FB")

    /// Raw fragmented HID stream characteristic (FF11). Notify carries frame fragments; read returns 16-byte status.
    public static let streamCharUUID = CBUUID(string: "0000FF11-0000-1000-8000-00805F9B34FB")

    /// Decoded 56-byte stream characteristic (FF12). Notify only.
    public static let decodedCharUUID = CBUUID(string: "0000FF12-0000-1000-8000-00805F9B34FB")

    /// Controller config block characteristic (FF13). Read windows & write cursor.
    public static let configCharUUID = CBUUID(string: "0000FF13-0000-1000-8000-00805F9B34FB")

    /// Batched decoded stream characteristic (FF14). Up to 9 records per notification, notify only.
    public static let batchedCharUUID = CBUUID(string: "0000FF14-0000-1000-8000-00805F9B34FB")

    /// Echo latency probe characteristic (FF15). Write without response (ping) and notify (pong).
    public static let echoCharUUID = CBUUID(string: "0000FF15-0000-1000-8000-00805F9B34FB")

    /// Client Characteristic Configuration Descriptor (0x2902).
    public static let cccDescriptorUUID = CBUUID(string: "00002902-0000-1000-8000-00805F9B34FB")

    // MARK: - ATT & Protocol Errors

    /// ATT application error returned by the bridge when enabling a stream while another is active.
    /// The client must write 0x0000 to the active CCC before enabling another stream.
    public static let attErrorOtherStreamActive: UInt8 = 0x80

    // MARK: - MTU Constraints

    /// Smallest ATT MTU that carries one FF12 record (56 + 3 ATT opcode/handle).
    public static let decodedMinMTU: Int = 59

    /// Smallest ATT MTU that carries one FF14 batch of one record (3 + 2 header + 56 record).
    public static let batchedMinMTU: Int = 61

    /// Highest standard ATT MTU requested after connecting.
    public static let requestedMTU: Int = 517

    // MARK: - Raw Fragment (FF11) Wire Sizes

    public static let fragmentMagic: UInt8 = 0x52
    public static let fragmentHeaderSize: Int = 12
    public static let maxFrameSize: Int = 64
    public static let maxNotificationSize: Int = 244
    public static let attNotifyOverhead: Int = 3

    // MARK: - Decoded Record (FF12) Wire Sizes

    public static let decodedRecordSize: Int = 56
    public static let decodedRecordVersion: UInt8 = 1
    public static let decodedFlagCalibrated: UInt8 = 0x01

    // MARK: - Batched Record (FF14) Wire Sizes

    public static let batchVersion: UInt8 = 2
    public static let batchHeaderSize: Int = 2
    public static let batchMaxRecordCount: Int = 9

    // MARK: - Echo Probe (FF15) Wire Sizes

    public static let echoVersion: UInt8 = 1
    public static let echoRequestSize: Int = 4
    public static let echoAnswerSize: Int = 20

    // MARK: - Config Block (FF13) Wire Sizes

    public static let configVersion: UInt8 = 1
    public static let configHeaderSize: Int = 16
    public static let configCursorSize: Int = 5
    public static let configWindowMax: Int = 496
    public static let configKeySize: Int = 1024
    public static let configSkipBytes: Int = 2

    // MARK: - Sensor Clock Constants

    /// Controller sensor timer period: 100 ns per tick.
    public static let tickNanoseconds: Double = 100.0
    public static let tickSeconds: Double = 1e-7

    /// 32-bit tick wrap modulus (2^32).
    public static let tickModulus: UInt64 = 0x1_0000_0000
}
