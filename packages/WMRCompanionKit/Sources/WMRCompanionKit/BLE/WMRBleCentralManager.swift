import Foundation
import CoreBluetooth
import Combine

/// Discovered bridge advertisement info.
public struct WMRDiscoveredBridge: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let peripheral: CBPeripheral

    public init(peripheral: CBPeripheral, rssi: Int) {
        self.id = peripheral.identifier
        self.name = peripheral.name ?? WMRConstants.defaultDeviceName
        self.rssi = rssi
        self.peripheral = peripheral
    }

    public static func == (lhs: WMRDiscoveredBridge, rhs: WMRDiscoveredBridge) -> Bool {
        lhs.id == rhs.id
    }
}

/// Raw notification packet stamped at arrival.
public struct WMRRawNotification: Sendable {
    public let characteristicUUID: CBUUID
    public let data: Data
    public let arrivalTimestampNanos: UInt64
}

/// Native CoreBluetooth central manager for WMR Bridge.
public final class WMRBleCentralManager: NSObject, @unchecked Sendable {
    private var centralManager: CBCentralManager!
    private var activePeripheral: CBPeripheral?

    // Discovered characteristics
    private var streamChar: CBCharacteristic?    // FF11
    private var decodedChar: CBCharacteristic?   // FF12
    private var configChar: CBCharacteristic?    // FF13
    private var batchedChar: CBCharacteristic?   // FF14
    private var echoChar: CBCharacteristic?      // FF15

    // Stream state tracking
    private var activeStreamChar: CBCharacteristic?
    private var targetStreamMode: WMRStreamMode = .batchedFF14

    // Combine Publishers
    public let statePublisher = CurrentValueSubject<WMRConnectionState, Never>(.disconnected)
    public let discoveredBridgesPublisher = PassthroughSubject<WMRDiscoveredBridge, Never>()
    public let notificationPublisher = PassthroughSubject<WMRRawNotification, Never>()
    public let rssiPublisher = PassthroughSubject<Int, Never>()

    // Negotiation state
    public private(set) var negotiatedMTU: Int = 23

    public override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    public func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        statePublisher.send(.scanning)
        centralManager.scanForPeripherals(
            withServices: [WMRConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    public func stopScanning() {
        if centralManager.isScanning {
            centralManager.stopScan()
            if statePublisher.value == .scanning {
                statePublisher.send(.disconnected)
            }
        }
    }

    public func connect(to bridge: WMRDiscoveredBridge) {
        stopScanning()
        activePeripheral = bridge.peripheral
        activePeripheral?.delegate = self
        statePublisher.send(.connecting)
        centralManager.connect(bridge.peripheral, options: nil)
    }

    public func disconnect() {
        if let p = activePeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
    }

    /// Sets stream mode, handling the bridge's mutual exclusion requirement (writing 0x0000 to active CCC first).
    public func setStreamMode(_ mode: WMRStreamMode) {
        targetStreamMode = mode
        guard let p = activePeripheral, p.state == .connected else { return }

        // Disable currently active stream if different
        if let active = activeStreamChar {
            let activeMode: WMRStreamMode
            if active.uuid == WMRConstants.streamCharUUID { activeMode = .rawFF11 }
            else if active.uuid == WMRConstants.decodedCharUUID { activeMode = .decodedFF12 }
            else if active.uuid == WMRConstants.batchedCharUUID { activeMode = .batchedFF14 }
            else { activeMode = .none }

            if activeMode != mode {
                p.setNotifyValue(false, for: active)
                activeStreamChar = nil
            } else {
                return // Already in target mode
            }
        }

        // Enable new target characteristic
        switch mode {
        case .none:
            break
        case .rawFF11:
            if let c = streamChar {
                p.setNotifyValue(true, for: c)
                activeStreamChar = c
            }
        case .decodedFF12:
            if let c = decodedChar {
                p.setNotifyValue(true, for: c)
                activeStreamChar = c
            }
        case .batchedFF14:
            if let c = batchedChar {
                p.setNotifyValue(true, for: c)
                activeStreamChar = c
            }
        }
    }

    /// Sends an FF15 echo ping write without response.
    public func sendEchoPing(data: Data) {
        guard let p = activePeripheral, let c = echoChar else { return }
        p.writeValue(data, for: c, type: .withoutResponse)
    }

    /// Writes cursor to FF13.
    public func writeConfigCursor(data: Data) {
        guard let p = activePeripheral, let c = configChar else { return }
        p.writeValue(data, for: c, type: .withResponse)
    }

    /// Reads window from FF13.
    public func readConfigWindow() {
        guard let p = activePeripheral, let c = configChar else { return }
        p.readValue(for: c)
    }

    public func readRSSI() {
        activePeripheral?.readRSSI()
    }
}

// MARK: - CBCentralManagerDelegate
extension WMRBleCentralManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if statePublisher.value == .disconnected {
                // Ready to scan
            }
        case .poweredOff:
            statePublisher.send(.failed("Bluetooth is powered off"))
        case .unauthorized:
            statePublisher.send(.failed("Bluetooth permission unauthorized"))
        case .unsupported:
            statePublisher.send(.failed("Bluetooth LE is unsupported on this device"))
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let bridge = WMRDiscoveredBridge(peripheral: peripheral, rssi: RSSI.intValue)
        discoveredBridgesPublisher.send(bridge)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        statePublisher.send(.discoveringServices)
        // Query maximum write length for withoutResponse (standard iOS mechanism for MTU estimation)
        let maxWrite = peripheral.maximumWriteValueLength(for: .withoutResponse)
        self.negotiatedMTU = maxWrite + WMRConstants.attNotifyOverhead
        peripheral.discoverServices([WMRConstants.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        statePublisher.send(.failed(error?.localizedDescription ?? "Connection failed"))
        activePeripheral = nil
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        statePublisher.send(.disconnected)
        activePeripheral = nil
        streamChar = nil
        decodedChar = nil
        configChar = nil
        batchedChar = nil
        echoChar = nil
        activeStreamChar = nil
    }
}

// MARK: - CBPeripheralDelegate
extension WMRBleCentralManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == WMRConstants.serviceUUID {
            peripheral.discoverCharacteristics([
                WMRConstants.streamCharUUID,
                WMRConstants.decodedCharUUID,
                WMRConstants.configCharUUID,
                WMRConstants.batchedCharUUID,
                WMRConstants.echoCharUUID
            ], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for c in characteristics {
            switch c.uuid {
            case WMRConstants.streamCharUUID:
                self.streamChar = c
            case WMRConstants.decodedCharUUID:
                self.decodedChar = c
            case WMRConstants.configCharUUID:
                self.configChar = c
                // Subscribe to config state changes
                peripheral.setNotifyValue(true, for: c)
            case WMRConstants.batchedCharUUID:
                self.batchedChar = c
            case WMRConstants.echoCharUUID:
                self.echoChar = c
                // Subscribe to echo responses
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }

        statePublisher.send(.ready)

        // Enable target stream mode
        setStreamMode(targetStreamMode)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // High-precision nanosecond timestamp stamped immediately at callback entry
        let arrivalTimestamp = DispatchTime.now().uptimeNanoseconds

        if let error = error as? CBATTError, error.code.rawValue == Int(WMRConstants.attErrorOtherStreamActive) {
            // Other stream active error
            return
        }

        guard let data = characteristic.value else { return }

        let rawNotification = WMRRawNotification(
            characteristicUUID: characteristic.uuid,
            data: data,
            arrivalTimestampNanos: arrivalTimestamp
        )
        notificationPublisher.send(rawNotification)
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        rssiPublisher.send(RSSI.intValue)
    }
}
