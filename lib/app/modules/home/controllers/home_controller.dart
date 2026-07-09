import 'dart:async';
// import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'; // Added
import 'package:get/get.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../../../data/models/ble_location_data.dart';
import '../../ble/controllers/ble_controller.dart';

class HomeController extends GetxController {
  final _nativeBridge = const MethodChannel(
    'com.example.gpsspoofshare/native_bridge',
  );

  final isAndroid = (!kIsWeb && Platform.isAndroid).obs;
  final isActive = false.obs;

  // Fixed initial position for GoogleMap to prevent re-rendering the platform view
  final initialPosition = const LatLng(23.8103, 90.4125);
  final currentPosition = const LatLng(23.8103, 90.4125).obs;

  GoogleMapController? mapController;

  // Route Simulation Variables
  final polylines = <Polyline>[].obs;
  Timer? _routeTimer;
  List<LatLng> _currentRoute = [];
  int _routeIndex = 0;
  final double _simulationSpeedKmH = 40.0; // 40 km/h simulation speed

  @override
  void onInit() {
    super.onInit();
    _requestPermissionsAndLocation();
    _setupMethodChannelListener();
  }

  @override
  void onClose() {
    _routeTimer?.cancel();
    super.onClose();
  }

  Future<void> _requestPermissionsAndLocation() async {
    if (isAndroid.value) {
      await [
        Permission.location,
        Permission.bluetooth,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.notification,
      ].request();
    } else if (Platform.isIOS) {
      await [Permission.location, Permission.bluetooth].request();
    }

    if (Get.isRegistered<BleController>()) {
      Get.find<BleController>().onPermissionsGranted();
    }

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (serviceEnabled) {
        Position? position = await Geolocator.getLastKnownPosition();

        position ??= await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 5),
          ),
        );
        currentPosition.value = LatLng(position.latitude, position.longitude);
        mapController?.animateCamera(
          CameraUpdate.newLatLng(currentPosition.value),
        );
      }
    } catch (e) {
      debugPrint("Failed to get location: $e");
    }
  }

  void _setupMethodChannelListener() {
    _nativeBridge.setMethodCallHandler((call) async {
      if (call.method == "onLocationUpdate") {
        final data = jsonDecode(call.arguments as String);
        final lat = data['lat'] as double;
        final lng = data['lng'] as double;
        currentPosition.value = LatLng(lat, lng);
        mapController?.animateCamera(
          CameraUpdate.newLatLng(currentPosition.value),
        );
      }
    });
  }

  void toggleAction() async {
    if (isActive.value) {
      // Stop
      try {
        await _nativeBridge.invokeMethod(
          isAndroid.value ? 'stopSpoofing' : 'stopReceiving',
        );
        isActive.value = false;
        _stopSimulation();
      } catch (e) {
        Get.snackbar("Error", "Failed to stop: $e");
      }
    } else {
      // Start
      try {
        await _nativeBridge.invokeMethod(
          isAndroid.value ? 'startSpoofing' : 'startReceiving',
        );
        isActive.value = true;

        if (isAndroid.value) {
          _updateNativeLocation(currentPosition.value);
        }
      } catch (e) {
        if (e is PlatformException && e.code == 'MOCK_LOCATION_NOT_ENABLED') {
          Get.defaultDialog(
            title: "Setup Required",
            middleText:
                "Please go to Developer Options on your phone and select this app as the 'Mock location app'.",
            textConfirm: "OK",
            onConfirm: () => Get.back(),
          );
        } else {
          Get.snackbar("Error", "Failed to start: $e");
        }
      }
    }
  }

  void onMapCreated(GoogleMapController controller) {
    mapController = controller;
    // Animate to current position once map is created
    mapController?.animateCamera(CameraUpdate.newLatLng(currentPosition.value));
  }

  void onMapTap(LatLng position) {
    if (isAndroid.value) {
      _stopSimulation(); // Stop any active auto-pilot
      currentPosition.value = position;
      if (isActive.value) {
        _updateNativeLocation(position);
      }
    }
  }

  void onMapLongPress(LatLng destination) async {
    if (!isAndroid.value || !isActive.value) return;

    Get.snackbar("Calculating Route", "Finding path to destination...");

    try {
      final start = currentPosition.value;
      // Use HTTPS to prevent Android cleartext blocks/interceptions, and build the URI properly
      final url = Uri.https(
        'router.project-osrm.org',
        '/route/v1/driving/${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}',
        {'overview': 'full', 'geometries': 'polyline'},
      );

      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final String polylineStr = data['routes'][0]['geometry'];
          _currentRoute = _decodePolyline(polylineStr);

          if (_currentRoute.isNotEmpty) {
            polylines.value = [
              Polyline(
                polylineId: const PolylineId('route'),
                color: Colors.blue,
                width: 5,
                points: _currentRoute,
              ),
            ];
            _startSimulation();
          }
        }
      } else {
        Get.snackbar("Error", "Failed to find a route.");
      }
    } catch (e) {
      Get.snackbar("Error", "Route calculation failed: $e");
    }
  }

  void _startSimulation() {
    _stopSimulation();
    _routeIndex = 0;

    // Simulate at 10Hz
    _routeTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (_routeIndex >= _currentRoute.length - 1) {
        _stopSimulation();
        Get.snackbar("Arrived", "You have reached your destination.");
        return;
      }

      final start = currentPosition.value;
      final end = _currentRoute[_routeIndex + 1];

      // Calculate distance to next point
      final distance = Geolocator.distanceBetween(
        start.latitude,
        start.longitude,
        end.latitude,
        end.longitude,
      );

      // Distance moved in 100ms at simulation speed
      final moveDist = (_simulationSpeedKmH * 1000 / 3600) * 0.1;

      if (distance <= moveDist) {
        // Reached next point
        currentPosition.value = end;
        _routeIndex++;
      } else {
        // Interpolate point
        final ratio = moveDist / distance;
        final newLat = start.latitude + (end.latitude - start.latitude) * ratio;
        final newLng =
            start.longitude + (end.longitude - start.longitude) * ratio;
        currentPosition.value = LatLng(newLat, newLng);
      }

      mapController?.animateCamera(
        CameraUpdate.newLatLng(currentPosition.value),
      );
      _updateNativeLocation(currentPosition.value);
    });
  }

  void _stopSimulation() {
    _routeTimer?.cancel();
    _routeTimer = null;
    polylines.clear();
  }

  void _updateNativeLocation(LatLng pos) {
    _nativeBridge.invokeMethod('updateSpoofLocation', {
      'lat': pos.latitude,
      'lng': pos.longitude,
    });
  }

  /// Called by [BleController] when a GPS location update is received from
  /// the BLE host device.  Updates the map position and, if spoofing is
  /// active, pushes the coordinates into the native mock-location pipeline.
  void onBleLocationReceived(BleLocationData data) {
    final newPos = LatLng(data.latitude, data.longitude);
    currentPosition.value = newPos;
    mapController?.animateCamera(CameraUpdate.newLatLng(newPos));
    if (isActive.value) {
      _updateNativeLocation(newPos);
    }
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      poly.add(LatLng((lat / 1E5).toDouble(), (lng / 1E5).toDouble()));
    }
    return poly;
  }
}
