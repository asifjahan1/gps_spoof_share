import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../controllers/home_controller.dart';
import '../../../routes/app_pages.dart';

class HomeView extends GetView<HomeController> {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Obx(
          () => Text(
            controller.isAndroid.value ? 'Sender (Android)' : 'Receiver (iOS)',
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bluetooth),
            tooltip: 'BLE Devices',
            onPressed: () => Get.toNamed(Routes.BLE),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Optimize Map: The initialCameraPosition is static to prevent deep rebuilds.
          // Changes to currentPosition will animate the camera via the controller.
          Obx(
            () => GoogleMap(
              initialCameraPosition: CameraPosition(
                target: controller.initialPosition,
                zoom: 14.0,
              ),
              mapType: MapType.hybrid,
              onMapCreated: controller.onMapCreated,
              onTap: controller.onMapTap,
              onLongPress: controller.onMapLongPress, // Added for Auto-Pilot
              polylines: controller.polylines.toSet(),
              markers: {
                Marker(
                  markerId: const MarkerId('target'),
                  position: controller.currentPosition.value,
                  infoWindow: const InfoWindow(title: 'Current Location'),
                ),
              },
            ),
          ),

          // Instructions Toast
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Obx(
                () => Text(
                  controller.isActive.value
                      ? "Tap to teleport. Long Press to Auto-Pilot to a destination! 🚗"
                      : "Start Spoofing first to simulate movement.",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),

          // Start/Stop Button
          Positioned(
            bottom: 100,
            left: 20,
            right: 20,
            child: Obx(
              () => ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: controller.isActive.value
                      ? Colors.red
                      : Colors.green,
                ),
                onPressed: controller.toggleAction,
                child: Text(
                  controller.isActive.value
                      ? 'Stop'
                      : (controller.isAndroid.value
                            ? 'Start Spoofing & Broadcast'
                            : 'Start Scanning & Track'),
                  style: const TextStyle(fontSize: 18, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
