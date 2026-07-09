import Flutter
import UIKit
import CoreBluetooth
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
  
  var centralManager: CBCentralManager!
  var spoofPeripheral: CBPeripheral?
  var methodChannel: FlutterMethodChannel?
  
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
