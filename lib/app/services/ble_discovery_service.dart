import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../data/models/ble_device_model.dart';
import '../data/models/ble_location_data.dart';

/// The role that this device is currently playing in the BLE mesh.
enum BleRole {
  /// Not participating in BLE discovery.
  none,

  /// Acting as Host – broadcasts GPS coordinates to connected clients.
  host,

  /// Acting as Client – receives GPS coordinates from a connected host.
  client,
}

/// Core service that manages all BLE discovery, connection, and GPS
/// synchronisation via a dedicated platform channel.
///
/// This service is registered as a permanent [GetxService] so it survives
/// page navigation and continues operating while the app is in the foreground
/// or background.
///
/// It communicates with native [BleDiscoveryManager] implementations on
/// Android (Kotlin) and iOS (Swift) through the
/// `com.example.gpsspoofshare/ble_discovery` [MethodChannel].
class BleDiscoveryService extends GetxService {
  static const _channelName = 'com.example.gpsspoofshare/ble_discovery';
  late final MethodChannel _channel;

  // ---------------------------------------------------------------------------
  // Reactive state
  // ---------------------------------------------------------------------------

  /// Whether the device's Bluetooth adapter is powered on.
  final isBluetoothOn = false.obs;

  /// Whether a BLE scan is currently in progress.
  final isScanning = false.obs;

  /// The current role of this device.
  final currentRole = BleRole.none.obs;

  /// All nearby devices discovered during the most recent scan.
  final discoveredDevices = <BleDeviceModel>[].obs;

  /// Devices that are currently connected.
  final connectedDevices = <BleDeviceModel>[].obs;

  /// The ID of the device acting as the current host (only relevant for clients).
  final currentHostId = ''.obs;

  /// The last error message received from the native layer.
  final lastError = ''.obs;

  // ---------------------------------------------------------------------------
  // Callbacks
  // ---------------------------------------------------------------------------

  /// Invoked when a GPS location update is received from the host (client mode).
  void Function(BleLocationData)? onLocationReceived;

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Timer? _staleDeviceTimer;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void onInit() {
    super.onInit();
    _channel = const MethodChannel(_channelName);
    _channel.setMethodCallHandler(_handleNativeCall);
    _checkBluetoothState();
    _startStaleDeviceCleanup();
  }

  @override
  void onClose() {
    _staleDeviceTimer?.cancel();
    _channel.setMethodCallHandler(null);
    super.onClose();
  }

  // ---------------------------------------------------------------------------
  // Public API – Scanning
  // ---------------------------------------------------------------------------

  /// Begins scanning for nearby devices advertising the discovery service UUID.
  Future<void> startScan() async {
    if (!isBluetoothOn.value) {
      lastError.value = 'Bluetooth is turned off';
      return;
    }
    try {
      discoveredDevices.clear();
      await _channel.invokeMethod('startScan');
      isScanning.value = true;
      lastError.value = '';
    } on PlatformException catch (e) {
      lastError.value = e.message ?? 'Failed to start scan';
      debugPrint('BleDiscoveryService.startScan error: $e');
    }
  }

  /// Stops an active BLE scan.
  Future<void> stopScan() async {
    try {
      await _channel.invokeMethod('stopScan');
      isScanning.value = false;
    } on PlatformException catch (e) {
      debugPrint('BleDiscoveryService.stopScan error: $e');
    }
  }

  /// Clears discovered devices and starts a fresh scan.
  Future<void> refreshScan() async {
    await stopScan();
    discoveredDevices.clear();
    await startScan();
  }

  // ---------------------------------------------------------------------------
  // Public API – Connection
  // ---------------------------------------------------------------------------

  /// Initiates a connection to the device with the given [deviceId].
  Future<void> connectToDevice(String deviceId) async {
    try {
      // Update state optimistically
      _updateDeviceState(deviceId, BleConnectionState.connecting);
      await _channel.invokeMethod('connectToDevice', {'id': deviceId});
      lastError.value = '';
    } on PlatformException catch (e) {
      _updateDeviceState(deviceId, BleConnectionState.disconnected);
      lastError.value = e.message ?? 'Connection failed';
      debugPrint('BleDiscoveryService.connectToDevice error: $e');
    }
  }

  /// Disconnects from the device with the given [deviceId].
  Future<void> disconnectDevice(String deviceId) async {
    try {
      await _channel.invokeMethod('disconnectDevice', {'id': deviceId});
      lastError.value = '';
    } on PlatformException catch (e) {
      debugPrint('BleDiscoveryService.disconnectDevice error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Public API – Host / Client roles
  // ---------------------------------------------------------------------------

  /// Starts Host mode: the device begins advertising and accepting connections.
  Future<void> startHostMode() async {
    if (!isBluetoothOn.value) {
      lastError.value = 'Bluetooth is turned off';
      return;
    }
    try {
      await _channel.invokeMethod('startHostMode');
      currentRole.value = BleRole.host;
      lastError.value = '';
    } on PlatformException catch (e) {
      lastError.value = e.message ?? 'Failed to start host mode';
      debugPrint('BleDiscoveryService.startHostMode error: $e');
    }
  }

  /// Stops Host mode and disconnects all clients.
  Future<void> stopHostMode() async {
    try {
      await _channel.invokeMethod('stopHostMode');
      currentRole.value = BleRole.none;
      connectedDevices.clear();
    } on PlatformException catch (e) {
      debugPrint('BleDiscoveryService.stopHostMode error: $e');
    }
  }

  /// Switches this device to Client mode.
  Future<void> startClientMode() async {
    try {
      await _channel.invokeMethod('startClientMode');
      currentRole.value = BleRole.client;
      lastError.value = '';
    } on PlatformException catch (e) {
      lastError.value = e.message ?? 'Failed to start client mode';
      debugPrint('BleDiscoveryService.startClientMode error: $e');
    }
  }

  /// Stops Client mode and disconnects from the host.
  Future<void> stopClientMode() async {
    try {
      await _channel.invokeMethod('stopClientMode');
      currentRole.value = BleRole.none;
      connectedDevices.clear();
      currentHostId.value = '';
    } on PlatformException catch (e) {
      debugPrint('BleDiscoveryService.stopClientMode error: $e');
    }
  }

  /// Broadcasts a GPS location to all connected clients (host mode only).
  Future<void> broadcastLocation(BleLocationData data) async {
    if (currentRole.value != BleRole.host) return;
    try {
      await _channel.invokeMethod(
        'broadcastLocation',
        jsonEncode(data.toMap()),
      );
    } on PlatformException catch (e) {
      debugPrint('BleDiscoveryService.broadcastLocation error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Native → Dart call handler
  // ---------------------------------------------------------------------------

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onDeviceDiscovered':
        _onDeviceDiscovered(call.arguments);
        break;
      case 'onDeviceConnected':
        _onDeviceConnected(call.arguments);
        break;
      case 'onDeviceDisconnected':
        _onDeviceDisconnected(call.arguments);
        break;
      case 'onLocationReceived':
        _onLocationReceived(call.arguments);
        break;
      case 'onBluetoothStateChanged':
        _onBluetoothStateChanged(call.arguments);
        break;
      case 'onScanStopped':
        isScanning.value = false;
        break;
      case 'onError':
        lastError.value = call.arguments as String? ?? 'Unknown error';
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Event handlers
  // ---------------------------------------------------------------------------

  void _onDeviceDiscovered(dynamic args) {
    if (args == null) return;
    final map = Map<String, dynamic>.from(args as Map);
    final device = BleDeviceModel.fromMap(map);

    final idx = discoveredDevices.indexWhere((d) => d.id == device.id);
    if (idx >= 0) {
      // Update existing device (refresh RSSI and lastSeen)
      final existing = discoveredDevices[idx];
      discoveredDevices[idx] = device.copyWith(
        connectionState: existing.connectionState,
      );
    } else {
      discoveredDevices.add(device);
    }
  }

  void _onDeviceConnected(dynamic args) {
    if (args == null) return;
    final map = Map<String, dynamic>.from(args as Map);
    final deviceId = map['id'] as String? ?? '';
    final deviceName = map['name'] as String? ?? 'Unknown';

    _updateDeviceState(deviceId, BleConnectionState.connected);

    // Add to connected list if not already present
    if (!connectedDevices.any((d) => d.id == deviceId)) {
      connectedDevices.add(
        BleDeviceModel(
          id: deviceId,
          name: deviceName,
          rssi: map['rssi'] as int? ?? -50,
          connectionState: BleConnectionState.connected,
          platform: _parsePlatformString(map['platform'] as String?),
          lastSeen: DateTime.now(),
        ),
      );
    }

    // If we are a client, record the host ID
    if (currentRole.value == BleRole.client) {
      currentHostId.value = deviceId;
    }
  }

  void _onDeviceDisconnected(dynamic args) {
    if (args == null) return;
    final map = Map<String, dynamic>.from(args as Map);
    final deviceId = map['id'] as String? ?? '';

    _updateDeviceState(deviceId, BleConnectionState.disconnected);
    connectedDevices.removeWhere((d) => d.id == deviceId);

    if (currentHostId.value == deviceId) {
      currentHostId.value = '';
    }
  }

  void _onLocationReceived(dynamic args) {
    if (args == null) return;

    Map<String, dynamic> map;
    if (args is String) {
      map = Map<String, dynamic>.from(jsonDecode(args) as Map);
    } else {
      map = Map<String, dynamic>.from(args as Map);
    }

    final locationData = BleLocationData.fromMap(map);
    onLocationReceived?.call(locationData);
  }

  void _onBluetoothStateChanged(dynamic args) {
    final state = args as bool? ?? false;
    isBluetoothOn.value = state;

    if (!state) {
      isScanning.value = false;
      discoveredDevices.clear();
      connectedDevices.clear();
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Queries the native layer for the current Bluetooth adapter state.
  Future<void> _checkBluetoothState() async {
    try {
      final result = await _channel.invokeMethod<bool>('isBluetoothOn');
      isBluetoothOn.value = result ?? false;
    } on PlatformException catch (e) {
      debugPrint('BleDiscoveryService._checkBluetoothState error: $e');
    }
  }

  /// Updates the connection state of a device in the discovered list.
  void _updateDeviceState(String deviceId, BleConnectionState state) {
    final idx = discoveredDevices.indexWhere((d) => d.id == deviceId);
    if (idx >= 0) {
      discoveredDevices[idx] = discoveredDevices[idx].copyWith(
        connectionState: state,
      );
    }
  }

  /// Removes devices that haven't been seen for more than 15 seconds.
  void _startStaleDeviceCleanup() {
    _staleDeviceTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final cutoff = DateTime.now().subtract(const Duration(seconds: 15));
      discoveredDevices.removeWhere(
        (d) =>
            d.connectionState == BleConnectionState.disconnected &&
            d.lastSeen.isBefore(cutoff),
      );
    });
  }

  BlePlatform _parsePlatformString(String? value) {
    switch (value?.toLowerCase()) {
      case 'android':
        return BlePlatform.android;
      case 'ios':
        return BlePlatform.ios;
      default:
        return BlePlatform.unknown;
    }
  }
}
