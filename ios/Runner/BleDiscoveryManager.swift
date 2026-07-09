import Foundation
import CoreBluetooth
import Flutter

/// Manages BLE discovery, connection, and GPS data synchronisation for the
/// in-app device-to-device communication feature on iOS.
///
/// Operates on a **separate** set of UUIDs from the existing CoreBluetooth
/// implementation in `AppDelegate` to avoid interference.
///
/// Supports two roles:
/// - **Host (Peripheral)**: Advertises a GATT service via `CBPeripheralManager`,
///   accepts connections, and broadcasts GPS data to all subscribed centrals.
/// - **Client (Central)**: Scans for hosts via `CBCentralManager`, connects,
///   and receives GPS notifications.
class BleDiscoveryManager: NSObject {

    // MARK: - Constants

    private let DISCOVERY_SERVICE_UUID = CBUUID(string: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    private let GPS_CHAR_UUID         = CBUUID(string: "a1b2c3d4-e5f6-7890-abcd-ef1234567891")
    private let DEVICE_INFO_CHAR_UUID = CBUUID(string: "a1b2c3d4-e5f6-7890-abcd-ef1234567892")

    private let RECONNECT_INITIAL_DELAY: TimeInterval = 1.0
    private let RECONNECT_MAX_DELAY: TimeInterval = 30.0

    // MARK: - Flutter channel

    var channel: FlutterMethodChannel?

    // MARK: - Central (Client mode)

    private var centralManager: CBCentralManager?
    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    private var connectedPeripherals: [String: CBPeripheral] = [:]
    private var isScanning = false
    private var isClientActive = false

    // MARK: - Peripheral (Host mode)

    private var peripheralManager: CBPeripheralManager?
    private var gpsCharacteristic: CBMutableCharacteristic?
    private var deviceInfoCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []
    private var isHostActive = false
    private var pendingServiceAdd = false

    // MARK: - Reconnect

    private var reconnectDelays: [String: TimeInterval] = [:]
    private var reconnectTimers: [String: Timer] = [:]

    // MARK: - Init

    override init() {
        super.init()
    }

    // MARK: - Public API

    /// Returns whether Bluetooth is powered on (based on central manager state).
    func isBluetoothOn() -> Bool {
        // Lazily initialise the central manager if needed
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
        return centralManager?.state == .poweredOn
    }

    // MARK: Scanning

    /// Starts scanning for peripherals advertising the discovery service UUID.
    func startScan() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }

        guard centralManager?.state == .poweredOn else {
            invokeFlutter("onError", arguments: "Bluetooth is not powered on")
            return
        }

        centralManager?.scanForPeripherals(
            withServices: [DISCOVERY_SERVICE_UUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
        print("[BleDiscoveryManager] Scan started")
    }

    /// Stops the active scan.
    func stopScan() {
        if isScanning {
            centralManager?.stopScan()
            isScanning = false
            invokeFlutter("onScanStopped", arguments: nil)
            print("[BleDiscoveryManager] Scan stopped")
        }
    }

    // MARK: Connection

    /// Connects to the peripheral with the given UUID string.
    func connectToDevice(_ deviceId: String) {
        cancelReconnect(deviceId)

        guard let peripheral = discoveredPeripherals[deviceId] else {
            invokeFlutter("onError", arguments: "Device not found: \(deviceId)")
            return
        }

        print("[BleDiscoveryManager] Connecting to \(deviceId)")
        centralManager?.connect(peripheral, options: nil)
    }

    /// Disconnects from the peripheral with the given UUID string.
    func disconnectDevice(_ deviceId: String) {
        cancelReconnect(deviceId)

        if let peripheral = connectedPeripherals[deviceId] {
            centralManager?.cancelPeripheralConnection(peripheral)
            connectedPeripherals.removeValue(forKey: deviceId)
        }

        invokeFlutter("onDeviceDisconnected", arguments: ["id": deviceId])
        print("[BleDiscoveryManager] Disconnected from \(deviceId)")
    }

    // MARK: Host mode

    /// Starts advertising and accepting client connections.
    func startHostMode() {
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        }

        guard peripheralManager?.state == .poweredOn else {
            // If not powered on yet, set flag and add service when state changes
            pendingServiceAdd = true
            isHostActive = true
            return
        }

        setupHostService()
        isHostActive = true
        print("[BleDiscoveryManager] Host mode started")
    }

    /// Stops advertising and closes peripheral manager.
    func stopHostMode() {
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        subscribedCentrals.removeAll()
        isHostActive = false
        print("[BleDiscoveryManager] Host mode stopped")
    }

    /// Broadcasts a GPS location JSON string to all subscribed centrals.
    func broadcastLocation(_ jsonString: String) {
        guard isHostActive, let characteristic = gpsCharacteristic else { return }
        guard let data = jsonString.data(using: .utf8) else { return }

        let didSend = peripheralManager?.updateValue(
            data,
            for: characteristic,
            onSubscribedCentrals: nil  // nil = all subscribed centrals
        )

        if didSend == false {
            // Queue is full; the peripheralManagerIsReady(toUpdateSubscribers:)
            // delegate method will be called when it's ready again.
            print("[BleDiscoveryManager] Update queue full, will retry")
        }
    }

    // MARK: Client mode

    /// Enables client mode.
    func startClientMode() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
        isClientActive = true
        print("[BleDiscoveryManager] Client mode started")
    }

    /// Disables client mode and disconnects from all hosts.
    func stopClientMode() {
        isClientActive = false
        stopScan()

        for (id, peripheral) in connectedPeripherals {
            cancelReconnect(id)
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        connectedPeripherals.removeAll()
        print("[BleDiscoveryManager] Client mode stopped")
    }

    // MARK: Cleanup

    /// Releases all resources.
    func destroy() {
        stopScan()
        stopHostMode()
        stopClientMode()
    }

    // MARK: - Private helpers

    private func setupHostService() {
        // GPS data characteristic (notify + read)
        gpsCharacteristic = CBMutableCharacteristic(
            type: GPS_CHAR_UUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )

        // Device info characteristic (read)
        let deviceName = UIDevice.current.name
        let infoJson = "{\"name\":\"\(deviceName)\",\"platform\":\"ios\"}"
        deviceInfoCharacteristic = CBMutableCharacteristic(
            type: DEVICE_INFO_CHAR_UUID,
            properties: [.read],
            value: infoJson.data(using: .utf8),
            permissions: [.readable]
        )

        let service = CBMutableService(type: DISCOVERY_SERVICE_UUID, primary: true)
        service.characteristics = [gpsCharacteristic!, deviceInfoCharacteristic!]

        peripheralManager?.removeAllServices()
        peripheralManager?.add(service)
    }

    private func startHostAdvertising() {
        peripheralManager?.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [DISCOVERY_SERVICE_UUID],
            CBAdvertisementDataLocalNameKey: UIDevice.current.name
        ])
    }

    // MARK: Auto-reconnect

    private func scheduleReconnect(_ deviceId: String) {
        let delay = reconnectDelays[deviceId] ?? RECONNECT_INITIAL_DELAY
        let nextDelay = min(delay * 2, RECONNECT_MAX_DELAY)
        reconnectDelays[deviceId] = nextDelay

        print("[BleDiscoveryManager] Scheduling reconnect to \(deviceId) in \(delay)s")

        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.isClientActive && self.connectedPeripherals[deviceId] == nil {
                if let peripheral = self.discoveredPeripherals[deviceId] {
                    self.centralManager?.connect(peripheral, options: nil)
                }
            }
        }
        reconnectTimers[deviceId]?.invalidate()
        reconnectTimers[deviceId] = timer
    }

    private func cancelReconnect(_ deviceId: String) {
        reconnectTimers[deviceId]?.invalidate()
        reconnectTimers.removeValue(forKey: deviceId)
        reconnectDelays.removeValue(forKey: deviceId)
    }

    // MARK: Flutter channel helper

    private func invokeFlutter(_ method: String, arguments: Any?) {
        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod(method, arguments: arguments)
        }
    }
}

// MARK: - CBCentralManagerDelegate (Client mode)

extension BleDiscoveryManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let isOn = central.state == .poweredOn
        invokeFlutter("onBluetoothStateChanged", arguments: isOn)

        if isOn {
            print("[BleDiscoveryManager] Central: Bluetooth powered on")
        } else {
            print("[BleDiscoveryManager] Central: Bluetooth powered off")
            isScanning = false
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let deviceId = peripheral.identifier.uuidString
        discoveredPeripherals[deviceId] = peripheral

        let deviceName = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Unknown"

        let deviceInfo: [String: Any] = [
            "id": deviceId,
            "name": deviceName,
            "rssi": RSSI.intValue,
            "platform": "unknown"
        ]
        invokeFlutter("onDeviceDiscovered", arguments: deviceInfo)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let deviceId = peripheral.identifier.uuidString
        connectedPeripherals[deviceId] = peripheral
        reconnectDelays.removeValue(forKey: deviceId)

        peripheral.delegate = self
        peripheral.discoverServices([DISCOVERY_SERVICE_UUID])

        let info: [String: Any] = [
            "id": deviceId,
            "name": peripheral.name ?? "Unknown",
            "platform": "unknown"
        ]
        invokeFlutter("onDeviceConnected", arguments: info)
        print("[BleDiscoveryManager] Connected to \(deviceId)")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let deviceId = peripheral.identifier.uuidString
        connectedPeripherals.removeValue(forKey: deviceId)

        invokeFlutter("onDeviceDisconnected", arguments: ["id": deviceId])
        print("[BleDiscoveryManager] Disconnected from \(deviceId)")

        // Auto-reconnect if client mode is active
        if isClientActive {
            scheduleReconnect(deviceId)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let deviceId = peripheral.identifier.uuidString
        invokeFlutter("onError", arguments: "Connection failed: \(error?.localizedDescription ?? "unknown")")

        if isClientActive {
            scheduleReconnect(deviceId)
        }
    }
}

// MARK: - CBPeripheralDelegate (Client mode – service/char discovery)

extension BleDiscoveryManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            print("[BleDiscoveryManager] Service discovery error: \(error!)")
            return
        }

        for service in peripheral.services ?? [] {
            if service.uuid == DISCOVERY_SERVICE_UUID {
                peripheral.discoverCharacteristics(
                    [GPS_CHAR_UUID, DEVICE_INFO_CHAR_UUID],
                    for: service
                )
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            print("[BleDiscoveryManager] Characteristic discovery error: \(error!)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == GPS_CHAR_UUID {
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == DEVICE_INFO_CHAR_UUID {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == GPS_CHAR_UUID {
            if let jsonStr = String(data: data, encoding: .utf8) {
                invokeFlutter("onLocationReceived", arguments: jsonStr)
            }
        } else if characteristic.uuid == DEVICE_INFO_CHAR_UUID {
            if let jsonStr = String(data: data, encoding: .utf8),
               let jsonData = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                let platform = json["platform"] as? String ?? "unknown"
                let name = json["name"] as? String ?? "Unknown"
                let info: [String: Any] = [
                    "id": peripheral.identifier.uuidString,
                    "name": name,
                    "platform": platform
                ]
                invokeFlutter("onDeviceConnected", arguments: info)
            }
        }
    }
}

// MARK: - CBPeripheralManagerDelegate (Host mode)

extension BleDiscoveryManager: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            print("[BleDiscoveryManager] Peripheral: Bluetooth powered on")
            if pendingServiceAdd && isHostActive {
                setupHostService()
                pendingServiceAdd = false
            }
        } else {
            print("[BleDiscoveryManager] Peripheral: Bluetooth powered off (\(peripheral.state.rawValue))")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            print("[BleDiscoveryManager] Failed to add service: \(error)")
            invokeFlutter("onError", arguments: "Failed to add BLE service: \(error.localizedDescription)")
            return
        }

        startHostAdvertising()
        print("[BleDiscoveryManager] Service added, advertising started")
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            print("[BleDiscoveryManager] Advertising failed: \(error)")
            invokeFlutter("onError", arguments: "Advertising failed: \(error.localizedDescription)")
        } else {
            print("[BleDiscoveryManager] Advertising started successfully")
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }

        let info: [String: Any] = [
            "id": central.identifier.uuidString,
            "name": "Client",
            "platform": "unknown"
        ]
        invokeFlutter("onDeviceConnected", arguments: info)
        print("[BleDiscoveryManager] Central subscribed: \(central.identifier)")
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }

        invokeFlutter("onDeviceDisconnected", arguments: ["id": central.identifier.uuidString])
        print("[BleDiscoveryManager] Central unsubscribed: \(central.identifier)")
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Called when the transmit queue has space again after a failed updateValue call.
        // In a production app you'd retry the last failed broadcast here.
        print("[BleDiscoveryManager] Peripheral manager ready to update subscribers")
    }
}
