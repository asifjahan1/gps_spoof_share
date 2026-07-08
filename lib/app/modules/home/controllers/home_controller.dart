import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:geolocator/geolocator.dart';

class HomeController extends GetxController {
  final _nativeBridge = const MethodChannel(
    'com.example.gpsspoofshare/native_bridge',
  );

  final isAndroid = (!kIsWeb && Platform.isAndroid).obs;
  final isActive = false.obs;

  // Default to a fallback location, will be updated immediately
  final currentPosition = const LatLng(37.7749, -122.4194).obs;
  GoogleMapController? mapController;

  @override
  void onInit() {
    super.onInit();
    _requestPermissionsAndLocation();
    _setupMethodChannelListener();
  }

  Future<void> _requestPermissionsAndLocation() async {
    if (isAndroid.value) {
      await [
        Permission.location,
        Permission.bluetooth,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.notification,
      ].request();
    } else if (Platform.isIOS) {
      await [Permission.location, Permission.bluetooth].request();
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

        // Immediately sync the current location to the native spoof service on Android
        if (isAndroid.value) {
          _nativeBridge.invokeMethod('updateSpoofLocation', {
            'lat': currentPosition.value.latitude,
            'lng': currentPosition.value.longitude,
          });
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
  }

  void onMapTap(LatLng position) {
    if (isAndroid.value) {
      currentPosition.value = position;
      if (isActive.value) {
        _nativeBridge.invokeMethod('updateSpoofLocation', {
          'lat': position.latitude,
          'lng': position.longitude,
        });
      }
    }
  }
}
