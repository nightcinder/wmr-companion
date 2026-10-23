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
    public private(set) var streamChar: CBCharacteristic?    // FF11
    public private(set) var decodedChar: CBCharacteristic?   // FF12
    public private(set) var configChar: CBCharacteristic?    // FF13
    public private(set) var batchedChar: CBCharacteristic?   // FF14
    public private(set) var echoChar: CBCharacteristic?      // FF15

    // Stream state tracking
    public private(set) var activeStreamChar: CBCharacteristic?
    private var targetStreamMode: WMRStreamMode = .batchedFF14

    // Combine Publishers
    public let statePublisher = CurrentValueSubject<WMRConnectionState, Never>(.disconnected)
    public let discoveredBridgesPublisher = PassthroughSubject<WMRDiscoveredBridge, Never>()
    public let notificationPublisher = PassthroughSubject<WMRRawNotification, Never>()
    public let rssiPublisher = PassthroughSubject<Int, Never>()
    public let streamErrorPublisher = PassthroughSubject<String, Never>()

    // Negotiation state (queried after discovery)
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

    public func refreshMTU() {
        guard let p = activePeripheral else { return }
        let maxWrite = p.maximumWriteValueLength(for: .withoutResponse)
        self.negotiatedMTU = maxWrite + WMRConstants.attNotifyOverhead
    }

    /// Sets stream mode, strictly writing 0x0000 to the active CCC before enabling the new target characteristic.
    public func setStreamMode(_ mode: WMRStreamMode) {
        targetStreamMode = mode
        guard let p = activePeripheral, p.state == .connected else { return }

        // Determine characteristic for requested mode
        let nextChar: CBCharacteristic?
        switch mode {
        case .none: nextChar = nil
        case .rawFF11: nextChar = streamChar
        case .decodedFF12: nextChar = decodedChar
        case .batchedFF14: nextChar = batchedChar
        }

        if let active = activeStreamChar, active != nextChar {
            // Disable active characteristic first
            p.setNotifyValue(false, for: active)
            // activeStreamChar is updated in didUpdateNotificationStateFor once disabled
        } else if let next = nextChar, activeStreamChar == nil {
            p.setNotifyValue(true, for: next)
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
        negotiatedMTU = 23
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
                peripheral.setNotifyValue(true, for: c)
            case WMRConstants.batchedCharUUID:
                self.batchedChar = c
            case WMRConstants.echoCharUUID:
                self.echoChar = c
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }

        // Query MTU *after* services and characteristics are discovered
        refreshMTU()
        statePublisher.send(.ready)

        // Enable target stream mode
        setStreamMode(targetStreamMode)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            if let attError = error as? CBATTError, attError.code.rawValue == Int(WMRConstants.attErrorOtherStreamActive) {
                streamErrorPublisher.send("ATT error 0x80: Another stream is already active on the bridge")
            } else {
                streamErrorPublisher.send("Notification state update failed: \(error.localizedDescription)")
            }
            if activeStreamChar == characteristic && !characteristic.isNotifying {
                activeStreamChar = nil
            }
            return
        }

        if characteristic.isNotifying {
            activeStreamChar = characteristic
        } else if activeStreamChar == characteristic {
            activeStreamChar = nil
            // Transition: active disabled, now enable target characteristic
            setStreamMode(targetStreamMode)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // High-precision nanosecond timestamp stamped immediately at callback entry
        let arrivalTimestamp = DispatchTime.now().uptimeNanoseconds

        guard error == nil, let data = characteristic.value else { return }

        let rawNotification = WMRRawNotification(
            characteristicUUID: characteristic.uuid,
            data: data,
            arrivalTimestampNanos: arrivalTimestamp
        )
        notificationPublisher.send(rawNotification)
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        refreshMTU()
        rssiPublisher.send(RSSI.intValue)
    }
}
