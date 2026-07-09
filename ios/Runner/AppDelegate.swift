import Flutter
import UIKit
import CoreBluetooth
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
  
  var centralManager: CBCentralManager!
  var spoofPeripheral: CBPeripheral?
  var methodChannel: FlutterMethodChannel?
  
  // BLE Discovery Manager (separate from existing BLE)
  var bleDiscoveryManager: BleDiscoveryManager?
  
  let SERVICE_UUID = CBUUID(string: "8e6c7087-0b1a-4648-9366-239617fa7259")
  let CHAR_UUID = CBUUID(string: "90b6d267-33e1-4c6e-827a-8f9f60cb0fc0")

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
      
    GeneratedPluginRegistrant.register(with: self)
      
    if let registrar = self.registrar(forPlugin: "NativeBridge") {
        methodChannel = FlutterMethodChannel(name: "com.example.gpsspoofshare/native_bridge", binaryMessenger: registrar.messenger())
        
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.example.gpsspoofshare.central"])
        
        methodChannel?.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "setGoogleMapsApiKey":
                if let args = call.arguments as? [String: Any],
                   let apiKey = args["apiKey"] as? String {
                    GMSServices.provideAPIKey(apiKey)
                    result("API Key Set")
                } else {
                    result(FlutterError(code: "INVALID_ARGS", message: "API Key missing", details: nil))
                }
            case "startReceiving":
                self?.startReceiving()
                result("Receiving Started")
            case "stopReceiving":
                self?.stopReceiving()
                result("Receiving Stopped")
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
    
    // ── BLE Discovery Channel (new, separate from existing BLE) ──────────
    if let registrar = self.registrar(forPlugin: "BleDiscovery") {
        bleDiscoveryManager = BleDiscoveryManager()
        let bleChannel = FlutterMethodChannel(
            name: "com.example.gpsspoofshare/ble_discovery",
            binaryMessenger: registrar.messenger()
        )
        bleDiscoveryManager?.channel = bleChannel
        
        bleChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard let manager = self?.bleDiscoveryManager else {
                result(FlutterError(code: "NOT_INIT", message: "BLE manager not initialized", details: nil))
                return
            }
            
            switch call.method {
            case "isBluetoothOn":
                result(manager.isBluetoothOn())
            case "startScan":
                manager.startScan()
                result(nil)
            case "stopScan":
                manager.stopScan()
                result(nil)
            case "connectToDevice":
                if let args = call.arguments as? [String: Any],
                   let id = args["id"] as? String {
                    manager.connectToDevice(id)
                }
                result(nil)
            case "disconnectDevice":
                if let args = call.arguments as? [String: Any],
                   let id = args["id"] as? String {
                    manager.disconnectDevice(id)
                }
                result(nil)
            case "startHostMode":
                manager.startHostMode()
                result(nil)
            case "stopHostMode":
                manager.stopHostMode()
                result(nil)
            case "startClientMode":
                manager.startClientMode()
                result(nil)
            case "stopClientMode":
                manager.stopClientMode()
                result(nil)
            case "broadcastLocation":
                if let json = call.arguments as? String {
                    manager.broadcastLocation(json)
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func startReceiving() {
      if centralManager.state == .poweredOn {
          centralManager.scanForPeripherals(withServices: [SERVICE_UUID], options: nil)
          print("Scanning for Android Spoof Server...")
      }
  }
  
  func stopReceiving() {
      centralManager.stopScan()
      if let peripheral = spoofPeripheral {
          centralManager.cancelPeripheralConnection(peripheral)
      }
  }
  
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
      if central.state == .poweredOn {
          print("Bluetooth is On.")
      } else {
          print("Bluetooth is Off.")
      }
  }
  
  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
      if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
          for peripheral in restoredPeripherals {
              spoofPeripheral = peripheral
              spoofPeripheral?.delegate = self
          }
      }
  }
  
  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
      print("Discovered: \(peripheral.name ?? "Unknown")")
      spoofPeripheral = peripheral
      centralManager.stopScan()
      centralManager.connect(peripheral, options: nil)
  }
  
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
      print("Connected to \(peripheral.name ?? "Unknown")")
      peripheral.delegate = self
      peripheral.discoverServices([SERVICE_UUID])
  }
  
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
      print("Disconnected. Reconnecting...")
      startReceiving()
  }
  
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
      if let services = peripheral.services {
          for service in services {
              if service.uuid == SERVICE_UUID {
                  peripheral.discoverCharacteristics([CHAR_UUID], for: service)
              }
          }
      }
  }
  
  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
      if let characteristics = service.characteristics {
          for characteristic in characteristics {
              if characteristic.uuid == CHAR_UUID {
                  peripheral.setNotifyValue(true, for: characteristic)
              }
          }
      }
  }
  
  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
      if characteristic.uuid == CHAR_UUID {
          if let data = characteristic.value {
              if let str = String(data: data, encoding: .utf8) {
                  print("Received Data: \(str)")
                  methodChannel?.invokeMethod("onLocationUpdate", arguments: str)
              }
          }
      }
  }
}

