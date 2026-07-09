/// Represents the connection state of a BLE device.
enum BleConnectionState {
  /// Device has been discovered but is not connected.
  disconnected,

  /// A connection attempt is in progress.
  connecting,

  /// Device is fully connected and communicating.
  connected,
}

/// Represents the platform of a discovered BLE device.
enum BlePlatform {
  /// Android device.
  android,

  /// iOS device.
  ios,

  /// Platform could not be determined.
  unknown,
}

/// Data model representing a BLE device discovered during scanning.
///
/// Each device is uniquely identified by its [id] (the platform-level
/// Bluetooth address on Android or peripheral UUID on iOS).
class BleDeviceModel {
  /// Platform-level device identifier (MAC address on Android, UUID on iOS).
  final String id;

  /// Human-readable device name, or "Unknown" if not advertised.
  final String name;

  /// Received Signal Strength Indicator in dBm.  More negative = weaker.
  final int rssi;

  /// Current connection state of this device.
  final BleConnectionState connectionState;

  /// The operating-system platform of this device, if determinable.
  final BlePlatform platform;

  /// The last time this device was seen during a scan.
  final DateTime lastSeen;

  const BleDeviceModel({
    required this.id,
    required this.name,
    required this.rssi,
    required this.connectionState,
    required this.platform,
    required this.lastSeen,
  });

  /// Creates an updated copy of this model with the given fields replaced.
  BleDeviceModel copyWith({
    String? id,
    String? name,
    int? rssi,
    BleConnectionState? connectionState,
    BlePlatform? platform,
    DateTime? lastSeen,
  }) {
    return BleDeviceModel(
      id: id ?? this.id,
      name: name ?? this.name,
      rssi: rssi ?? this.rssi,
      connectionState: connectionState ?? this.connectionState,
      platform: platform ?? this.platform,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  /// Deserialises a device from a map received over the platform channel.
  factory BleDeviceModel.fromMap(Map<String, dynamic> map) {
    return BleDeviceModel(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? 'Unknown',
      rssi: map['rssi'] as int? ?? -100,
      connectionState: BleConnectionState.disconnected,
      platform: _parsePlatform(map['platform'] as String?),
      lastSeen: DateTime.now(),
    );
  }

  /// Converts this model to a map for platform channel transmission.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'rssi': rssi,
      'connectionState': connectionState.name,
      'platform': platform.name,
    };
  }

  static BlePlatform _parsePlatform(String? value) {
    switch (value?.toLowerCase()) {
      case 'android':
        return BlePlatform.android;
      case 'ios':
        return BlePlatform.ios;
      default:
        return BlePlatform.unknown;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BleDeviceModel &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
