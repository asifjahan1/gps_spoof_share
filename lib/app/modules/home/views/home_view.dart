import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../controllers/home_controller.dart';

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
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Obx(
                  () => GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: controller.currentPosition.value,
                      zoom: 14.0,
                    ),
                    onMapCreated: controller.onMapCreated,
                    onTap: controller.onMapTap,
                    markers: {
                      Marker(
                        markerId: const MarkerId('target'),
                        position: controller.currentPosition.value,
                        infoWindow: const InfoWindow(title: 'Current Location'),
                      ),
                    },
                  ),
                ),
                Positioned(
                  bottom: 30,
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
                        style: const TextStyle(
                          fontSize: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
