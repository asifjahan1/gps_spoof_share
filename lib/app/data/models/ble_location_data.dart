/// Data model for GPS location payloads transmitted over BLE.
///
/// This is the data structure that the Host broadcasts to all connected
/// Client devices.  It is serialised to JSON for BLE transmission.
class BleLocationData {
  /// Latitude in decimal degrees.
  final double latitude;

  /// Longitude in decimal degrees.
  final double longitude;

  /// Horizontal accuracy in metres.
  final double accuracy;

  /// Altitude above sea level in metres (0.0 if unavailable).
  final double altitude;

  /// Speed in metres per second (0.0 if unavailable).
  final double speed;

  /// Bearing / heading in degrees (0.0 if unavailable).
  final double bearing;

  /// Unix timestamp in milliseconds when this location was recorded.
  final int timestamp;

  const BleLocationData({
    required this.latitude,
    required this.longitude,
    this.accuracy = 1.0,
    this.altitude = 0.0,
    this.speed = 0.0,
    this.bearing = 0.0,
    required this.timestamp,
  });

  /// Deserialises from a JSON-compatible map (received over BLE or platform channel).
  factory BleLocationData.fromMap(Map<String, dynamic> map) {
    return BleLocationData(
      latitude: (map['lat'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['lng'] as num?)?.toDouble() ?? 0.0,
      accuracy: (map['accuracy'] as num?)?.toDouble() ?? 1.0,
      altitude: (map['altitude'] as num?)?.toDouble() ?? 0.0,
      speed: (map['speed'] as num?)?.toDouble() ?? 0.0,
      bearing: (map['bearing'] as num?)?.toDouble() ?? 0.0,
      timestamp: (map['ts'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Serialises to a JSON-compatible map for BLE transmission.
  Map<String, dynamic> toMap() {
    return {
      'lat': latitude,
      'lng': longitude,
      'accuracy': accuracy,
      'altitude': altitude,
      'speed': speed,
      'bearing': bearing,
      'ts': timestamp,
    };
  }

  @override
  String toString() =>
      'BleLocationData(lat: $latitude, lng: $longitude, ts: $timestamp)';
}
