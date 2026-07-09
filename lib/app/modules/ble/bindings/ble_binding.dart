import 'package:get/get.dart';
import '../controllers/ble_controller.dart';

class BleBinding extends Bindings {
  @override
  void dependencies() {
    Get.find<BleController>();
  }
}
