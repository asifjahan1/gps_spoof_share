import 'package:get/get.dart';
import '../controllers/home_controller.dart';
import '../../../services/ble_discovery_service.dart';
import '../../ble/controllers/ble_controller.dart';

class HomeBinding extends Bindings {
  @override
  void dependencies() {
    // Register BLE discovery service as permanent (survives page navigation)
    Get.put<BleDiscoveryService>(BleDiscoveryService(), permanent: true);
    Get.put<HomeController>(HomeController(), permanent: true);
    Get.put<BleController>(BleController(), permanent: true);
  }
}

