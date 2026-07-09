import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../data/models/ble_device_model.dart';
import '../../../data/models/ble_location_data.dart';
import '../../../services/ble_discovery_service.dart';
import '../../home/controllers/home_controller.dart';

/// Controller for the BLE discovery and connection management page.
///
/// Delegates all BLE operations to [BleDiscoveryService] and integrates
/// with [HomeController] for GPS coordinate synchronisation:
///
/// - **Host mode**: listens to [HomeController.currentPosition] changes and
///   broadcasts them to connected clients via BLE.
/// - **Client mode**: receives GPS updates from the host and pushes them
///   into [HomeController] to update the map and spoofing state.
class BleController extends GetxController {
  late final BleDiscoveryService _bleService;
  late final HomeController _homeController;

  /// Worker that monitors position changes in Host mode.
  Worker? _positionWorker;

  // ---------------------------------------------------------------------------
  // Getters that delegate to BleDiscoveryService reactive state
  // ---------------------------------------------------------------------------

  RxBool get isBluetoothOn => _bleService.isBluetoothOn;
  RxBool get isScanning => _bleService.isScanning;
  Rx<BleRole> get currentRole => _bleService.currentRole;
  RxList<BleDeviceModel> get discoveredDevices => _bleService.discoveredDevices;
  RxList<BleDeviceModel> get connectedDevices => _bleService.connectedDevices;
  RxString get currentHostId => _bleService.currentHostId;
  RxString get lastError => _bleService.lastError;

  bool get isHost => currentRole.value == BleRole.host;
  bool get isClient => currentRole.value == BleRole.client;

  @override
  void onInit() {
    super.onInit();
    _bleService = Get.find<BleDiscoveryService>();
    _homeController = Get.find<HomeController>();

    // Register location callback for client mode
    _bleService.onLocationReceived = _onLocationFromHost;

    // Automatically become a host (broadcaster) when Bluetooth is turned on
    // unless we are currently connected as a client.
    ever<bool>(isBluetoothOn, (isOn) {
      if (isOn && !isClient) {
        _becomeHost();
      } else if (!isOn) {
        _stopHost();
      }
    });

    // Also monitor role changes to auto-revert to host if we disconnect as a client
    ever<BleRole>(currentRole, (role) {
      if (role == BleRole.none && isBluetoothOn.value) {
        _becomeHost();
      }
    });

    if (isBluetoothOn.value) {
      _becomeHost();
    }
  }

  /// Called by HomeController after the user has granted necessary permissions.
  /// This ensures that if the app booted up before permissions were granted,
  /// we retry starting the host mode.
  void onPermissionsGranted() {
    if (isBluetoothOn.value && !isClient) {
      _becomeHost();
    }
  }

  @override
  void onClose() {
    _positionWorker?.dispose();
    _bleService.onLocationReceived = null;
    super.onClose();
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  /// Starts a BLE scan for nearby devices.
  void startScan() {
    _bleService.startScan();
  }

  /// Stops an active scan.
  void stopScan() {
    _bleService.stopScan();
  }

  /// Clears discovered devices and restarts the scan.
  void refreshScan() {
    _bleService.refreshScan();
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  /// Connects to the device with the given [deviceId].
  /// Automatically switches this device to Client mode (receiver).
  void connectToDevice(String deviceId) {
    _becomeClient();
    _bleService.connectToDevice(deviceId);
  }

  /// Disconnects from the device with the given [deviceId].
  void disconnectDevice(String deviceId) {
    _bleService.disconnectDevice(deviceId);
    // When the connection drops, the service will eventually set the role to none,
    // and our ever() listener will automatically revert us to host mode.
  }

  // ---------------------------------------------------------------------------
  // Automated Role management
  // ---------------------------------------------------------------------------

  /// Activates Host mode: this device advertises and broadcasts GPS to clients.
  void _becomeHost() {
    if (isClient) {
      _bleService.stopClientMode();
    }

    _bleService.startHostMode();

    // Start watching HomeController.currentPosition for changes
    _positionWorker?.dispose();
    _positionWorker = ever<LatLng>(_homeController.currentPosition, (position) {
      if (_bleService.currentRole.value == BleRole.host) {
        final data = BleLocationData(
          latitude: position.latitude,
          longitude: position.longitude,
          accuracy: 1.0,
          altitude: 3.0,
          speed: 0.0,
          bearing: 0.0,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        _bleService.broadcastLocation(data);
      }
    });
  }

  /// Deactivates Host mode.
  void _stopHost() {
    _positionWorker?.dispose();
    _positionWorker = null;
    _bleService.stopHostMode();
  }

  /// Activates Client mode: this device stops advertising and listens for GPS from a host.
  void _becomeClient() {
    if (isHost) {
      _stopHost();
    }
    _bleService.startClientMode();
  }

  // ---------------------------------------------------------------------------
  // GPS synchronisation
  // ---------------------------------------------------------------------------

  /// Called when a GPS location is received from the host (client mode).
  void _onLocationFromHost(BleLocationData data) {
    _homeController.onBleLocationReceived(data);
  }

  // ---------------------------------------------------------------------------
  // UI helpers
  // ---------------------------------------------------------------------------

  /// Returns a human-readable label for the Bluetooth state.
  String get bluetoothStatusText =>
      isBluetoothOn.value ? 'Bluetooth ON' : 'Bluetooth OFF';

  /// Returns a human-readable label for the current role.
  String get roleText {
    switch (currentRole.value) {
      case BleRole.host:
        return 'Broadcasting Location';
      case BleRole.client:
        return 'Receiving Location';
      case BleRole.none:
        return 'Disconnected';
    }
  }

  /// Returns an icon for the given RSSI value.
  IconData rssiIcon(int rssi) {
    if (rssi >= -50) return Icons.signal_cellular_4_bar;
    if (rssi >= -70) return Icons.signal_cellular_alt;
    if (rssi >= -85) return Icons.signal_cellular_alt_2_bar;
    return Icons.signal_cellular_alt_1_bar;
  }

  /// Returns a colour for the given connection state.
  Color connectionColor(BleConnectionState state) {
    switch (state) {
      case BleConnectionState.connected:
        return Colors.green;
      case BleConnectionState.connecting:
        return Colors.orange;
      case BleConnectionState.disconnected:
        return Colors.grey;
    }
  }

  /// Returns a platform icon for the given platform.
  IconData platformIcon(BlePlatform platform) {
    switch (platform) {
      case BlePlatform.android:
        return Icons.android;
      case BlePlatform.ios:
        return Icons.phone_iphone;
      case BlePlatform.unknown:
        return Icons.devices;
    }
  }
}
